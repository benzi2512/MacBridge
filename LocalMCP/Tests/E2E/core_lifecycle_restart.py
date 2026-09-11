#!/usr/bin/env python3
"""Finite lifecycle acceptance for an exact reviewed core, never a live owner.

Uses only a fresh temporary workspace/private Unix socket and an environment
without inherited credentials. No tunnel, login service or GUI is started.
Only children created by this test may be terminated. No mutating tools called.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def frame(stream, deadline):
    data = b""
    while b"\n" not in data:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([stream], [], [], remaining)[0], "RPC timed out"
        chunk = os.read(stream.fileno(), 65536)
        assert chunk, "Child exited before RPC completed"
        data += chunk
        assert len(data) <= 1048576, "Unexpected oversized response"
    return json.loads(data.split(b"\n", 1)[0])


def rpc(child, identifier, method, params):
    child.stdin.write((json.dumps({"jsonrpc": "2.0", "id": identifier,
                                  "method": method, "params": params}) + "\n").encode())
    child.stdin.flush()
    value = frame(child.stdout, time.monotonic() + 5)
    assert value.get("id") == identifier and "error" not in value, value
    return value["result"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    assert digest(binary) == args.sha256, "Exact approved binary required"
    results = []
    catalog_hash = None
    owners = set()
    with tempfile.TemporaryDirectory(prefix="mb-lc-", dir="/private/tmp") as folder:
        root = Path(folder)
        workspace = root / "work"
        workspace.mkdir(mode=0o700)
        observer = root / "observe"
        observer.mkdir(mode=0o700)
        sentinel = workspace / "sentinel.txt"
        sentinel.write_text("Synthetic lifecycle sentinel; never altered by MCP.\n")
        sentinel_hash = digest(sentinel)
        config = root / "workspaces.json"
        config.write_text(json.dumps({"version": 1, "workspaces": [{
            "id": "11111111-2222-4333-8444-555555555555", "name": "Lifecycle fixture",
            "path": str(workspace), "allow_broad_access": False}]}))
        config.chmod(0o600)
        for index, shutdown in enumerate(["graceful", "crash", "graceful", "crash", "crash", "graceful"]):
            assert digest(binary) == args.sha256, "Binary changed between cycles"
            started = time.monotonic()
            with (root / "stderr.log").open("wb") as errors:
                child = subprocess.Popen([str(binary), "--config", str(config), "--surface", "web-tunnel",
                    "--observer-directory", str(observer)], cwd=workspace,
                    env={"PATH": "/usr/bin:/bin", "TMPDIR": str(root)},
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, bufsize=0)
                try:
                    init = rpc(child, 1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                        "clientInfo": {"name": "isolated-lifecycle-test", "version": "1"}})
                    assert init["protocolVersion"] == "2025-06-18"
                    catalog = rpc(child, 2, "tools/list", {})["tools"]
                    names = {tool["name"] for tool in catalog}
                    assert len(catalog) == 70 and {"brevo_read", "brevo_campaign",
                        "brevo_contacts", "brevo_lists", "brevo_events", "brevo_webhooks"} <= names
                    current_hash = hashlib.sha256(json.dumps(catalog, sort_keys=True,
                                                            separators=(",", ":")).encode()).hexdigest()
                    if catalog_hash is None:
                        catalog_hash = current_hash
                    assert current_hash == catalog_hash, "Catalog changed across identical-binary restart"
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(5)
                        connection.connect(str(observer / "observer.sock"))
                        connection.sendall(b'{"action":"snapshot"}\n')
                        response = b""
                        while b"\n" not in response:
                            chunk = connection.recv(65536)
                            assert chunk, "Observer closed before completing snapshot"
                            response += chunk
                            assert len(response) <= 1048576
                        snapshot = json.loads(response)
                    assert snapshot["ok"] is True
                    owner = snapshot["result"]["instance_id"]
                    assert owner not in owners, "Restart reused an old owner identity"
                    owners.add(owner)
                    assert digest(sentinel) == sentinel_hash
                    results.append({"cycle": index + 1, "shutdown": shutdown,
                        "startup_ms": round((time.monotonic() - started) * 1000),
                        "catalog_count": len(catalog), "new_owner": True})
                    if shutdown == "crash":
                        child.kill()
                    else:
                        child.stdin.close()
                    child.wait(timeout=5)
                    assert child.returncode == (-9 if shutdown == "crash" else 0)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
                    for stream in (child.stdin, child.stdout):
                        if stream is not None and not stream.closed:
                            stream.close()
        assert not (observer / "observer.sock").exists(), "Graceful shutdown left its socket behind"
        assert digest(sentinel) == sentinel_hash
    print(json.dumps({"status": "PASS", "binary_sha256": args.sha256, "cycles": results,
        "catalog_canonical_json_sha256": catalog_hash, "sentinel_unchanged": True,
        "production_runtime_touched": False, "real_reboot_tested": False,
        "chatgpt_restart_tested": False, "network_outage_tested": False}, indent=2))


if __name__ == "__main__":
    main()
