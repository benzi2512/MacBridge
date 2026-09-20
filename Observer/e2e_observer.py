#!/usr/bin/env python3
"""Disposable, offline owner/UI-channel test. Never starts the installed runtime."""
import argparse, hashlib, json, os, pathlib, select, socket, subprocess, sys, tempfile, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--binary", required=True)
ap.add_argument("--evidence", required=True)
ap.add_argument("--hold", action="store_true")
args = ap.parse_args()
binary = pathlib.Path(args.binary).resolve(strict=True)
evidence = pathlib.Path(args.evidence).resolve()
if evidence.exists():
    raise SystemExit("Evidence directory must be new")
evidence.mkdir(mode=0o700, parents=True)
workspace = evidence / "fixture"
workspace.mkdir(mode=0o700)
workspace_id = str(uuid.uuid4())
config = evidence / "workspaces.json"
config.write_text(json.dumps({"version": 1, "workspaces": [{"id": workspace_id, "name": "Disposable UI validation", "path": str(workspace)}]}))
config.chmod(0o600)
endpoint = pathlib.Path(tempfile.mkdtemp(prefix="mbui-", dir="/private/tmp"))
endpoint.chmod(0o700)
initial = b"MacBridge observer test\nXin ch\xc3\xa0o \xf0\x9f\x8c\x8f\nvalue=1\n"
sample = workspace / "sample.txt"
sample.write_bytes(initial)
outside = evidence / "outside-sentinel.txt"
outside.write_text("OUTSIDE_UNCHANGED\n")
outside_hash = hashlib.sha256(outside.read_bytes()).hexdigest()
events = []
checks = []
sequence = 0
p = None
identity = None
process_tokens = {}

def check(name, condition):
    checks.append({"name": name, "pass": bool(condition)})
    if not condition:
        raise AssertionError(name)

def rpc(name, **arguments):
    global sequence
    arguments = dict(arguments)
    task_id = arguments.get("task_id")
    if name in {"process_wait", "process_output", "process_output_tail", "process_input", "process_cancel"} \
            and isinstance(task_id, str) and task_id in process_tokens:
        arguments.setdefault("process_control_token", process_tokens[task_id])
    sequence += 1
    request = {"jsonrpc": "2.0", "id": sequence, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    p.stdin.write((json.dumps(request) + "\n").encode()); p.stdin.flush()
    if not select.select([p.stdout], [], [], 15)[0]:
        raise TimeoutError("MCP response timeout; mutation not replayed")
    result = json.loads(p.stdout.readline())
    events.append({"route": "stdio", "request": request, "response": result})
    tool = result.get("result", {})
    if tool.get("isError") or "error" in result:
        raise RuntimeError(json.dumps(result))
    structured = tool["structuredContent"]
    returned_task_id = structured.get("task_id")
    returned_token = structured.get("process_control_token")
    if isinstance(returned_task_id, str) and isinstance(returned_token, str):
        process_tokens[returned_task_id] = returned_token
    return structured

def observe(action, expected_error=False, **fields):
    payload = {"action": action, **fields}
    if identity is not None and "instance_id" not in payload:
        payload["instance_id"] = identity
    start = time.perf_counter()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(str(endpoint / "observer.sock"))
        client.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = client.recv(65536)
            if not chunk: raise RuntimeError("observer closed")
            data += chunk
            if len(data) > 1048576: raise RuntimeError("oversize response")
    result = json.loads(data.split(b"\n")[0])
    events.append({"route": "observer", "request": payload, "response": result, "milliseconds": (time.perf_counter()-start)*1000})
    if expected_error:
        check("Expected refusal: " + action, result.get("ok") is False)
        return result
    if not result.get("ok"): raise RuntimeError(json.dumps(result))
    return result["result"]

def start():
    global p, identity
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
           "HOME": os.path.expanduser("~"), "LANG": "en_US.UTF-8",
           "TMPDIR": tempfile.gettempdir()}
    err = open(evidence / "owner-stderr.log", "ab")
    p = subprocess.Popen([str(binary), "--config", str(config), "--surface", "web-tunnel",
                          "--observer-directory", str(endpoint)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env)
    err.close()
    for _ in range(100):
        if p.poll() is not None: raise RuntimeError("disposable owner failed startup")
        if (endpoint / "observer.sock").exists(): break
        time.sleep(0.02)
    identity = None
    identity = observe("snapshot")["instance_id"]
    check("stdio and observer share exact owner", rpc("bridge_capabilities")["instance_id"] == identity)

def patch(old, new):
    digest = hashlib.sha256(sample.read_bytes()).hexdigest()
    return rpc("file_patch", workspace_id=workspace_id, path="sample.txt",
               old_text=old, new_text=new, expected_sha256=digest)["transaction_id"]

def cleanup_owner():
    if p is None or p.poll() is not None: return
    for job in rpc("process_list")["processes"]:
        rpc("process_cancel", task_id=job["task_id"])
    # All transactions in this private owner were created by this harness.
    remaining = observe("snapshot")["transactions"]
    for tx in reversed(remaining):
        try:
            observe("restore", transaction_id=tx["transaction_id"], workspace_id=tx["workspace_id"])
        except RuntimeError:
            pass
    p.stdin.close()
    p.wait(timeout=10)

try:
    start()
    first_identity = identity
    first_pid = p.pid
    t1 = patch("value=1", "value=2")
    view = observe("transaction", transaction_id=t1, workspace_id=workspace_id)
    check("real before/current comparison", view["before"] == initial.decode() and "value=2" in view["after"])
    observe("restore", expected_error=True, instance_id=str(uuid.uuid4()),
            transaction_id=t1, workspace_id=workspace_id)
    observe("restore", expected_error=True, transaction_id=t1, workspace_id=str(uuid.uuid4()))
    t2 = patch("value=2", "value=3")
    before_conflict = sample.read_bytes()
    observe("restore", expected_error=True, transaction_id=t1, workspace_id=workspace_id)
    check("conflict did not change bytes", sample.read_bytes() == before_conflict)
    check("restore second readback", observe("restore", transaction_id=t2, workspace_id=workspace_id)["readback_verified"])
    check("restore first readback", observe("restore", transaction_id=t1, workspace_id=workspace_id)["readback_verified"])
    observe("restore", expected_error=True, transaction_id=t1, workspace_id=workspace_id)
    check("baseline restored", sample.read_bytes() == initial)

    a = rpc("command_start", workspace_id=workspace_id, executable="sh",
            arguments=["-c", "printf 'JOB_A_READY\n'; sleep 60"], maximum_output_bytes=4096)["task_id"]
    b = rpc("command_start", workspace_id=workspace_id, executable="python3",
            arguments=["-c", "import sys; v=sys.stdin.readline(); print(int(v)+1)"],
            maximum_output_bytes=4096)["task_id"]
    observe("cancel", expected_error=True, instance_id=str(uuid.uuid4()), task_id=a)
    check("UI cancels owned A", observe("cancel", task_id=a)["cancelled"])
    check("B survives A cancellation", rpc("process_status", task_id=b)["running"])
    rpc("process_input", task_id=b, content="41\n", close_stdin=True)
    for _ in range(100):
        if not rpc("process_status", task_id=b)["running"]: break
        time.sleep(.02)
    for _ in range(3):
        peek = observe("output", task_id=b)
        check("UI output does not consume B", peek["stdout"] == "42\n" and peek["session_retained"])
        rpc("process_status", task_id=b)
    check("Chat drains its own B", rpc("process_output", task_id=b)["session_retained"] is False)
    observe("output", expected_error=True, task_id=b)
    check("no job residue", rpc("process_list")["processes"] == [])
    samples = []
    for _ in range(20):
        begin = time.perf_counter(); observe("snapshot")
        samples.append((time.perf_counter()-begin)*1000)
    (evidence / "snapshot-latency.json").write_text(json.dumps({"samples_ms": samples, "max_ms": max(samples)}, indent=2))
    check("observer history bounded", len(observe("snapshot")["history"]) <= 64)
    cleanup_owner()
    check("graceful exit removes exact endpoint", not (endpoint / "observer.sock").exists())
    start()
    check("relaunch creates different owner", identity != first_identity)
    observe("snapshot", expected_error=True, instance_id=first_identity)
    check("new owner did not inherit jobs", rpc("process_list")["processes"] == [])
    check("new owner did not inherit undo", observe("snapshot")["transactions"] == [])

    if args.hold:
        ui_tx = patch("value=1", "value=2")
        ui_job = rpc("command_start", workspace_id=workspace_id, executable="python3",
                     arguments=["-c", "import sys; [print(f'PAGE_LINE_{i:04d}') for i in range(2000)]; print('UI job waiting for input',flush=True); sys.stdin.readline()"],
                     maximum_output_bytes=131072)["task_id"]
        hold = {"directory": str(endpoint), "owner_pid": p.pid, "instance_id": identity,
                "workspace_id": workspace_id, "transaction_id": ui_tx, "task_id": ui_job,
                "sample": str(sample), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
        (evidence / "hold.json").write_text(json.dumps(hold, indent=2))
        print("UI_HOLD_READY " + json.dumps(hold), flush=True)
        while select.select([sys.stdin], [], [], 600)[0]:
            command = sys.stdin.readline().strip()
            if command in {"finish", ""}: break
            if command == "status":
                print(json.dumps({"snapshot": observe("snapshot"), "sample": sample.read_text()}), flush=True)
            elif command == "finish-job":
                try: rpc("process_input", task_id=ui_job, content="done\n", close_stdin=True)
                except RuntimeError: pass
            elif command == "restart":
                cleanup_owner(); start()
                print("NEW_OWNER " + json.dumps({"pid": p.pid, "instance_id": identity}), flush=True)
    cleanup_owner()
    check("fixture restored after UI controls/cleanup", sample.read_bytes() == initial)
    check("outside sentinel unchanged", hashlib.sha256(outside.read_bytes()).hexdigest() == outside_hash)
    check("owner exited", p.poll() == 0)
    check("endpoint cleaned", not (endpoint / "observer.sock").exists())
finally:
    if p is not None and p.poll() is None:
        try: cleanup_owner()
        except Exception:
            p.terminate(); p.wait(timeout=5)
    (evidence / "events.json").write_text(json.dumps(events, indent=2, ensure_ascii=False))
    (evidence / "checks.json").write_text(json.dumps(checks, indent=2))
    if not list(endpoint.iterdir()): endpoint.rmdir()
print(json.dumps({"pass": all(c["pass"] for c in checks), "checks": len(checks), "evidence": str(evidence)}), flush=True)
