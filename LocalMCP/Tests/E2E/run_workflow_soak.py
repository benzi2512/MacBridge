#!/usr/bin/env python3
"""Finite, low-load, disposable owner-lifecycle soak. No tunnel or live config."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

from run_local_e2e import Evidence, MCPClient, sha256_file, sha256_bytes, write_configuration, wait_stopped


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--duration-seconds", type=int, default=7200)
    parser.add_argument("--interval-seconds", type=int, default=30)
    args = parser.parse_args()
    if not 20 <= args.duration_seconds <= 14400 or not 5 <= args.interval_seconds <= 300:
        parser.error("bounded duration 20..14400 and interval 5..300 required")
    binary = Path(args.binary).resolve(strict=True)
    if sha256_file(binary) != args.sha256:
        parser.error("binary identity differs from audited artifact")
    evidence_directory = Path(args.evidence_dir).resolve()
    if evidence_directory.exists():
        parser.error("evidence directory already exists; preserve earlier results")
    evidence = Evidence(evidence_directory)
    root = Path(tempfile.mkdtemp(prefix="macbridge-workflow-soak-"))
    workspace = root / "workspace"
    workspace.mkdir()
    workspace_id = str(uuid.uuid4())
    config = root / "workspaces.json"
    write_configuration(config, [(workspace_id, "disposable-soak", workspace)])
    baseline = "Xin chào 🌏\nvalue=1\n"
    changed = "Xin chào 🌏\nvalue=2\n"
    for name in ["cycle.txt", "held.txt"]:
        (workspace / name).write_text(baseline, encoding="utf-8")
    accepted_text = "kept=0\n"
    (workspace / "kept.txt").write_text(accepted_text, encoding="utf-8")
    client = MCPClient(binary, config, evidence, "web-tunnel")
    started = time.monotonic()
    cycles = 0
    failure = None
    resources = []
    latencies = []
    held = None
    summary_path = evidence.directory / "summary.json"
    summary = {
        "status": "RUNNING", "scope": "offline stdio web-profile, not ordinary Chat or tunnel",
        "binary_sha256": args.sha256, "owner_pid": client.process.pid, "fixture": str(root),
        "requested_duration_seconds": args.duration_seconds,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")

    def tool(name, arguments=None, **kwargs):
        before = time.monotonic()
        result = client.tool(name, arguments, **kwargs)
        latencies.append({"tool": name, "elapsed_ms": (time.monotonic() - before) * 1000})
        return result

    def sample(phase):
        completed = subprocess.run(
            ["/bin/ps", "-p", str(client.process.pid), "-o", "pid=,rss=,%cpu=,time="],
            capture_output=True, text=True, timeout=5, check=True)
        fields = completed.stdout.strip().split()
        if len(fields) != 4:
            raise RuntimeError("owner resource sample missing")
        row = {"at_unix": time.time(), "elapsed_seconds": time.monotonic() - started,
               "phase": phase, "pid": int(fields[0]), "rss_kib": int(fields[1]),
               "cpu_percent_snapshot": float(fields[2]), "cumulative_cpu_time": fields[3]}
        resources.append(row)
        evidence.append_json(evidence.directory / "resources.jsonl", row)

    try:
        client.initialize()
        identity = tool("bridge_capabilities")
        evidence.check(identity["mcp_executable_sha256"] == args.sha256, "owner uses exact artifact")
        owner = identity["instance_id"]
        held = tool("file_patch", {"workspace_id": workspace_id, "path": "held.txt",
                    "old_text": "value=1", "new_text": "value=2",
                    "expected_sha256": sha256_bytes(baseline.encode())})["transaction_id"]
        sample("initial")
        next_cycle = started
        while time.monotonic() - started < args.duration_seconds:
            if time.monotonic() >= next_cycle:
                current = tool("bridge_capabilities")
                evidence.check(current["instance_id"] == owner and
                               current["mcp_executable_sha256"] == args.sha256, "same owner and binary")
                patch = tool("file_patch", {"workspace_id": workspace_id, "path": "cycle.txt",
                             "old_text": "value=1", "new_text": "value=2",
                             "expected_sha256": sha256_bytes(baseline.encode())})
                read = tool("file_read", {"workspace_id": workspace_id, "path": "cycle.txt"})
                evidence.check(read["file"]["content"] == changed and
                               (workspace / "cycle.txt").read_text() == changed, "cycle mutation readback")
                tool("transaction_restore", {"transaction_id": patch["transaction_id"]})
                evidence.check((workspace / "cycle.txt").read_text() == baseline, "cycle hash restored")
                refused = tool("workspace_reload", expect_error=True)
                evidence.check("undo transactions" in str(refused), "held undo blocks reload")
                result = tool("file_search", {"workspace_id": workspace_id, "query": "value="})
                evidence.check(len(result["matches"]) == 2 and result["complete"], "search oracle")
                a = tool("command_start", {"workspace_id": workspace_id, "executable": "zsh",
                         "arguments": ["-f", "-c", "read reply; printf 'ACK:%s' \"$reply\""],
                         "maximum_output_bytes": 8192})["task_id"]
                b = tool("command_start", {"workspace_id": workspace_id, "executable": "zsh",
                         "arguments": ["-f", "-c", "printf '%20000s' x; printf TAIL"],
                         "maximum_output_bytes": 8192})["task_id"]
                # Deliberately consume B late; bounded tail and A ownership must survive.
                time.sleep(0.1)
                wait_stopped(client, b)
                output = tool("process_output", {"task_id": b})
                evidence.check(output["stdout"].endswith("TAIL") and
                               output["stdout_cursor_adjusted"] is True and
                               len(output["stdout"].encode()) <= 8192, "slow consumer bounded tail")
                evidence.check(tool("process_status", {"task_id": a})["running"], "independent A still running")
                sent = tool("process_input", {"task_id": a, "content": "ok\n", "close_stdin": True})
                evidence.check(sent["bytes_written"] == 3, "stdin exact, no replay")
                wait_stopped(client, a)
                evidence.check(tool("process_output", {"task_id": a})["stdout"] == "ACK:ok", "stdin output exact")
                evidence.check(tool("process_list")["processes"] == [], "no retained jobs")
                evidence.check((workspace / "held.txt").read_text() == changed, "long-lived undo still intact")
                # Exercise keep-and-release without discarding the deliberately
                # held undo or changing other tasks' current filesystem state.
                next_text = f"kept={cycles + 1}\n"
                accepted_write = tool("file_write", {"workspace_id": workspace_id,
                    "path": "kept.txt", "content": next_text,
                    "expected_sha256": sha256_bytes(accepted_text.encode())})
                accepted = tool("transaction_accept", {"instance_id": owner,
                    "transaction_ids": [accepted_write["transaction_id"]]})
                evidence.check(accepted["released_undo_file_bytes"] == len(accepted_text.encode())
                    and accepted["filesystem_mutation_performed"] is False
                    and (workspace / "kept.txt").read_text() == next_text,
                    "accept frees exact bytes and keeps completed file change")
                retained = tool("transaction_list")
                evidence.check(retained["retained_transaction_count"] == 1
                    and retained["retained_undo_file_bytes"] == len(baseline.encode())
                    and retained["transactions"][0]["transaction_id"] == held,
                    "accept never releases another task's held undo")
                accepted_text = next_text
                cycles += 1
                sample("after_cycle")
                next_cycle = time.monotonic() + args.interval_seconds
            remaining = args.duration_seconds - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(min(5, remaining))
                sample("idle")
        tool("transaction_restore", {"transaction_id": held})
        held = None
        evidence.check((workspace / "held.txt").read_text() == baseline, "long-lived undo restored")
        evidence.check(tool("workspace_reload")["reloaded"], "reload works after all undo restored")
        evidence.check(tool("process_list")["processes"] == [], "final owner has no jobs")
        evidence.check(sha256_file(binary) == args.sha256, "artifact unchanged after soak")
    except Exception as error:
        # An uncertain mutation is never replayed. Preserve fixture and RPC evidence.
        failure = f"{type(error).__name__}: {error}"
        evidence.observe("failure", failure)
    finally:
        elapsed = time.monotonic() - started
        exit_code = client.close() # closes only this disposable owner and its owned jobs
        if exit_code != 0:
            failure = failure or f"disposable owner exit={exit_code}"
        summary.update(status="FAIL" if failure else "PASS", failure=failure, cycles=cycles,
                       elapsed_seconds=elapsed, two_hour_duration_met=elapsed >= 7200,
                       checks=evidence.check_count, owner_exit_code=exit_code,
                       retained_fixture=True, pending_held_undo_at_exit=held is not None,
                       minimum_rss_kib=min((r["rss_kib"] for r in resources), default=None),
                       maximum_rss_kib=max((r["rss_kib"] for r in resources), default=None))
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        (evidence.directory / "latencies.json").write_text(json.dumps(latencies, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
    return 1 if failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
