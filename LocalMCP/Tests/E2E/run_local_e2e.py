#!/usr/bin/env python3
"""Finite, parameterized end-to-end gate for the MacBridge direct-local MCP."""
from __future__ import annotations
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
PROTOCOL_VERSION = '2025-06-18'
EXPECTED_TOOLS = {'bridge_capabilities', 'workspace_overview', 'workspace_list', 'workspace_reload', 'directory_list', 'file_stat', 'file_stat_many', 'file_read', 'file_read_many', 'file_search', 'file_write', 'file_patch', 'file_append', 'directory_create', 'path_copy', 'path_move', 'path_remove', 'transaction_restore', 'command_run', 'command_start', 'process_status', 'process_output', 'process_list', 'process_input', 'process_cancel'}
EXPECTED_TOOLS.update({'transaction_list', 'transaction_accept'})
EXPECTED_TOOLS.update({'bridge_activity_view', 'bridge_activity'})
EXPECTED_TOOLS.update({'work_task', 'developer_inspect', 'developer_task'})
EXPECTED_TOOLS.update({'tool_catalog', 'workspace_inspect', 'file_read_lines', 'file_tail',
    'file_compare', 'file_search_many', 'directory_summary', 'directory_find',
    'file_apply_edits', 'file_write_many', 'command_list', 'process_wait',
    'process_status_many', 'process_output_tail', 'process_output_many',
    'git_status', 'git_diff', 'git_log', 'git_show', 'git_branches', 'git_worktrees',
    'git_blame', 'git_file_list', 'brevo_read', 'brevo_campaign',
    'brevo_contacts', 'brevo_lists', 'brevo_segments', 'brevo_automations', 'brevo_templates',
    'brevo_events', 'brevo_transactional', 'brevo_deliverability', 'brevo_webhooks', 'brevo_reports'})
EXPECTED_TOOLS.update({'media_inspect', 'media_share', 'desktop_open', 'network_command'})
EXPECTED_TOOLS.update({'bridge_diagnostic', 'workspace_resolve', 'project_read_bundle',
    'file_json_patch', 'artifact_snapshot'})

def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

def milliseconds() -> int:
    return int(time.time() * 1000)

class GateFailure(RuntimeError):
    pass

class Evidence:

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=False)
        self.rpc_path = self.directory / 'rpc.jsonl'
        self.observation_path = self.directory / 'observations.jsonl'
        self.stderr_path = self.directory / 'server-stderr.log'
        self.sections: list[dict[str, object]] = []
        self.check_count = 0

    def append_json(self, path: Path, value: dict[str, object]) -> None:
        with path.open('a', encoding='utf-8') as handle:
            handle.write(json.dumps(value, sort_keys=True, ensure_ascii=False) + '\n')

    def rpc(self, direction: str, value: dict[str, object], elapsed_ms: int | None=None) -> None:
        row: dict[str, object] = {'at_ms': milliseconds(), 'direction': direction, 'message': value}
        if elapsed_ms is not None:
            row['elapsed_ms'] = elapsed_ms
        self.append_json(self.rpc_path, row)

    def observe(self, name: str, value: object) -> None:
        self.append_json(self.observation_path, {'at_ms': milliseconds(), 'name': name, 'value': value})

    def check(self, condition: bool, message: str, value: object=None) -> None:
        self.check_count += 1
        self.observe(f'check:{message}', {'passed': condition, 'value': value})
        if not condition:
            raise GateFailure(message)

    @contextlib.contextmanager
    def section(self, name: str):
        started = time.monotonic()
        row: dict[str, object] = {'name': name, 'status': 'RUNNING'}
        self.sections.append(row)
        try:
            yield
        except Exception:
            row['status'] = 'FAIL'
            row['elapsed_ms'] = int((time.monotonic() - started) * 1000)
            raise
        else:
            row['status'] = 'PASS'
            row['elapsed_ms'] = int((time.monotonic() - started) * 1000)

class MCPClient:

    def __init__(self, binary: Path, config: Path, evidence: Evidence, surface: str) -> None:
        self.binary = binary
        self.config = config
        self.evidence = evidence
        self.surface = surface
        self.next_id = 1
        self.pending_transactions: list[str] = []
        self.process_tokens: dict[str, str] = {}
        self.transaction_tokens: dict[str, str] = {}
        self.work_tokens: dict[str, str] = {}
        self.work_processes: dict[str, str] = {}
        self.stderr_handle = evidence.stderr_path.open('ab')
        self.process = subprocess.Popen([str(binary), '--config', str(config), '--surface', surface], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr_handle, bufsize=0)
        if self.process.stdin is None or self.process.stdout is None:
            raise GateFailure('failed to open MCP stdio pipes')

    def send(self, value: dict[str, object]) -> None:
        assert self.process.stdin is not None
        self.evidence.rpc('request', value)
        payload = json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
        self.process.stdin.write(payload + b'\n')
        self.process.stdin.flush()

    def receive(self, timeout_seconds: float=15.0) -> dict[str, object]:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        started = time.monotonic()
        try:
            ready = selector.select(timeout_seconds)
        finally:
            selector.close()
        if not ready:
            raise GateFailure('timed out waiting for MCP response')
        line = self.process.stdout.readline()
        if not line:
            raise GateFailure(f'MCP transport closed with exit {self.process.poll()}')
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise GateFailure(f'MCP returned malformed JSON: {error}') from error
        if not isinstance(value, dict):
            raise GateFailure('MCP response was not an object')
        self.evidence.rpc('response', value, int((time.monotonic() - started) * 1000))
        return value

    def request(self, method: str, params: dict[str, object]) -> dict[str, object]:
        request_id = self.next_id
        self.next_id += 1
        self.send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params})
        while True:
            response = self.receive()
            if response.get('id') is None and isinstance(response.get('method'), str):
                # Server notifications are independent of request responses.
                # A real MCP client routes them to its notification handler.
                continue
            break
        if response.get('id') != request_id:
            raise GateFailure(f'MCP response id mismatch for {method}')
        if 'error' in response:
            raise GateFailure(f"MCP protocol error for {method}: {response['error']}")
        result = response.get('result')
        if not isinstance(result, dict):
            raise GateFailure(f'MCP result missing for {method}')
        return result

    def notify(self, method: str, params: dict[str, object]) -> None:
        self.send({'jsonrpc': '2.0', 'method': method, 'params': params})

    def initialize(self) -> dict[str, object]:
        result = self.request('initialize', {'protocolVersion': PROTOCOL_VERSION, 'capabilities': {}, 'clientInfo': {'name': 'macbridge-local-e2e', 'version': '1'}})
        self.notify('notifications/initialized', {})
        return result

    def tool(self, name: str, arguments: dict[str, object] | None=None, *, expect_error: bool=False) -> dict[str, object]:
        prepared = dict(arguments or {})
        if self.surface == 'web-tunnel':
            work_id = prepared.get('work_id')
            if isinstance(work_id, str) and work_id in self.work_tokens:
                prepared.setdefault('work_control_token', self.work_tokens[work_id])
            if name == 'work_task' and prepared.get('action') in {'update', 'finish'}:
                work_id = prepared.get('work_id')
                if isinstance(work_id, str) and work_id in self.work_tokens:
                    prepared.setdefault('work_control_token', self.work_tokens[work_id])
            task_id = prepared.get('task_id')
            if name in {'process_wait', 'process_output', 'process_output_tail',
                        'process_input', 'process_cancel', 'bridge_activity'}:
                if isinstance(task_id, str) and task_id in self.process_tokens:
                    prepared.setdefault('process_control_token', self.process_tokens[task_id])
            if name == 'process_output_many' and isinstance(prepared.get('jobs'), list):
                jobs = []
                for raw_job in prepared['jobs']:
                    job = dict(raw_job)
                    task_id = job.get('task_id')
                    if isinstance(task_id, str) and task_id in self.process_tokens:
                        job.setdefault('process_control_token', self.process_tokens[task_id])
                    jobs.append(job)
                prepared['jobs'] = jobs
            if name == 'developer_task' and prepared.get('action') == 'continue_task':
                workflow_id = prepared.get('workflow_id')
                if isinstance(workflow_id, str):
                    if workflow_id in self.work_tokens:
                        prepared.setdefault('work_control_token', self.work_tokens[workflow_id])
                    task_id = self.work_processes.get(workflow_id)
                    if task_id in self.process_tokens:
                        prepared.setdefault('process_control_token', self.process_tokens[task_id])
            transaction_id = prepared.get('transaction_id')
            if name == 'transaction_restore' and isinstance(transaction_id, str):
                if transaction_id in self.transaction_tokens:
                    prepared.setdefault('transaction_control_token', self.transaction_tokens[transaction_id])
            if name == 'transaction_accept' and 'transaction_control_tokens' not in prepared:
                transaction_ids = prepared.get('transaction_ids')
                if isinstance(transaction_ids, list) and all(
                        isinstance(item, str) and item in self.transaction_tokens
                        for item in transaction_ids):
                    prepared['transaction_control_tokens'] = [
                        self.transaction_tokens[item] for item in transaction_ids
                    ]
        result = self.request('tools/call', {'name': name, 'arguments': prepared})
        is_error = result.get('isError') is True
        structured = result.get('structuredContent')
        if not isinstance(structured, dict):
            raise GateFailure(f'tool {name} omitted structuredContent')
        if is_error != expect_error:
            raise GateFailure(f'tool {name} error state was {is_error}: {structured}')
        if not is_error:
            task_id = structured.get('task_id')
            process_token = structured.get('process_control_token')
            if isinstance(task_id, str) and isinstance(process_token, str):
                self.process_tokens[task_id] = process_token
            work_id = structured.get('work_id') or structured.get('workflow_id')
            work_token = structured.get('work_control_token')
            if isinstance(work_id, str) and isinstance(work_token, str):
                self.work_tokens[work_id] = work_token
            if isinstance(work_id, str) and isinstance(task_id, str):
                self.work_processes[work_id] = task_id
            self._remember_transaction_tokens(structured)
        if not is_error and name == 'transaction_accept':
            for receipt in structured.get('accepted', []):
                transaction = receipt.get('transaction_id')
                if transaction in self.pending_transactions:
                    self.pending_transactions.remove(transaction)
        if not is_error and isinstance(structured.get('transaction_id'), str):
            transaction = structured['transaction_id']
            if name == 'transaction_restore':
                if transaction in self.pending_transactions:
                    self.pending_transactions.remove(transaction)
            else:
                self.pending_transactions.append(transaction)
        return structured

    def _remember_transaction_tokens(self, value: object) -> None:
        if isinstance(value, dict):
            transaction_id = value.get('transaction_id')
            token = value.get('transaction_control_token')
            if isinstance(transaction_id, str) and isinstance(token, str):
                self.transaction_tokens[transaction_id] = token
            for nested in value.values():
                self._remember_transaction_tokens(nested)
        elif isinstance(value, list):
            for nested in value:
                self._remember_transaction_tokens(nested)

    def close(self) -> int:
        if self.process.poll() is None:
            assert self.process.stdin is not None
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
        code = self.process.returncode
        self.stderr_handle.close()
        self.evidence.observe('mcp_exit', code)
        return code

def write_configuration(path: Path, workspaces: list[tuple[str, str, Path]], *, broad_id: str | None=None) -> None:
    value = {'version': 1, 'workspaces': [{'id': workspace_id, 'name': name, 'path': str(root)} for workspace_id, name, root in workspaces]}
    if broad_id is not None:
        value['workspaces'].append({'id': broad_id, 'name': 'Mac-test', 'path': '/', 'allow_broad_access': True})
    temporary = path.with_name(path.name + '.new')
    temporary.write_text(json.dumps(value, sort_keys=True), encoding='utf-8')
    temporary.chmod(stat.S_IRUSR | stat.S_IWUSR)
    os.replace(temporary, path)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)

def tool_write(client: MCPClient, workspace_id: str, path: str, content: str, expected_sha256: str | None=None) -> dict[str, object]:
    arguments: dict[str, object] = {'workspace_id': workspace_id, 'path': path, 'content': content}
    if expected_sha256 is not None:
        arguments['expected_sha256'] = expected_sha256
    return client.tool('file_write', arguments)

def run_command(client: MCPClient, workspace_id: str, command: str, *, timeout_ms: int=30000, maximum_output_bytes: int=1048576) -> dict[str, object]:
    return client.tool('command_run', {'workspace_id': workspace_id, 'executable': 'zsh', 'arguments': ['-f', '-c', command], 'cwd': '.', 'timeout_milliseconds': timeout_ms, 'maximum_output_bytes': maximum_output_bytes})

def wait_stopped(client: MCPClient, task_id: str, timeout_seconds: float=10.0) -> dict[str, object]:
    deadline = time.monotonic() + timeout_seconds
    status: dict[str, object] = {}
    while time.monotonic() < deadline:
        status = client.tool('process_status', {'task_id': task_id})
        if status.get('running') is False:
            return status
        time.sleep(0.03)
    raise GateFailure(f'process {task_id} did not stop within {timeout_seconds}s')

def read_process_output(client: MCPClient, task_id: str, stdout_cursor: int=0, stderr_cursor: int=0, maximum_bytes: int=1048576) -> dict[str, object]:
    return client.tool('process_output', {'task_id': task_id, 'stdout_cursor': stdout_cursor, 'stderr_cursor': stderr_cursor, 'maximum_bytes_per_stream': maximum_bytes})

def wait_output_contains(client: MCPClient, task_id: str, needle: str, timeout_seconds: float=10.0) -> dict[str, object]:
    deadline = time.monotonic() + timeout_seconds
    last: dict[str, object] = {}
    while time.monotonic() < deadline:
        last = read_process_output(client, task_id)
        combined = str(last.get('stdout', '')) + str(last.get('stderr', ''))
        if needle in combined:
            return last
        if last.get('running') is False:
            break
        time.sleep(0.03)
    raise GateFailure(f'process {task_id} output did not contain {needle!r}: {last}')

def send_process_bytes(client: MCPClient, task_id: str, payload: bytes, *, close_stdin: bool=False) -> None:
    offset = 0
    while offset < len(payload) or (not payload and offset == 0):
        chunk = payload[offset:offset + 48000]
        final_chunk = offset + len(chunk) == len(payload)
        result = client.tool('process_input', {'task_id': task_id, 'content': base64.b64encode(chunk).decode('ascii'), 'encoding': 'base64', 'close_stdin': close_stdin and final_chunk})
        written = result.get('bytes_written')
        if not isinstance(written, int) or written < 0 or written > len(chunk):
            raise GateFailure('process_input returned an invalid byte count')
        if written == 0:
            time.sleep(0.005)
        offset += written
        if not payload:
            break

def fetch_loopback(port: int) -> bytes:
    with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
        connection.sendall(b'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')
        response = bytearray()
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                break
            response.extend(chunk)
    marker = bytes(response).find(b'\r\n\r\n')
    if marker < 0:
        raise GateFailure('loopback server returned malformed HTTP')
    return bytes(response[marker + 4:])

def read_utf8_file_by_chunks(client: MCPClient, workspace_id: str, path: str, maximum_bytes: int) -> bytes:
    rebuilt = bytearray()
    offset = 0
    while True:
        result = client.tool('file_read', {'workspace_id': workspace_id, 'path': path, 'encoding': 'utf8', 'maximum_bytes': maximum_bytes, 'offset': offset})
        file = result.get('file')
        if not isinstance(file, dict):
            raise GateFailure('file_read omitted file result')
        content = file.get('content')
        next_offset = file.get('next_offset')
        if not isinstance(content, str) or not isinstance(next_offset, int) or next_offset <= offset:
            raise GateFailure('file_read did not advance UTF-8 cursor')
        rebuilt.extend(content.encode('utf-8'))
        offset = next_offset
        if file.get('eof') is True:
            return bytes(rebuilt)

def read_binary_file_by_chunks(client: MCPClient, workspace_id: str, path: str, maximum_bytes: int) -> bytes:
    rebuilt = bytearray()
    offset = 0
    while True:
        result = client.tool('file_read', {'workspace_id': workspace_id, 'path': path, 'encoding': 'base64', 'maximum_bytes': maximum_bytes, 'offset': offset})
        file = result.get('file')
        if not isinstance(file, dict):
            raise GateFailure('file_read omitted binary file result')
        content = file.get('content')
        next_offset = file.get('next_offset')
        if not isinstance(content, str) or not isinstance(next_offset, int) or next_offset <= offset:
            raise GateFailure('file_read did not advance binary cursor')
        rebuilt.extend(base64.b64decode(content, validate=True))
        offset = next_offset
        if file.get('eof') is True:
            return bytes(rebuilt)

def run_gate(args: argparse.Namespace, evidence: Evidence, root: Path) -> dict[str, object]:
    binary = Path(args.binary).expanduser().resolve(strict=True)
    workspace = root / 'workspace'
    workspace.mkdir()
    config = root / 'workspaces.json'
    workspace_id = str(uuid.uuid4())
    write_configuration(config, [(workspace_id, 'e2e-workspace', workspace)])
    sentinel = workspace / 'sentinel.txt'
    sentinel_bytes = b'sentinel-baseline\n'
    sentinel.write_bytes(sentinel_bytes)
    sentinel_hash = sha256_file(sentinel)
    evidence.observe('binary', {'path': str(binary), 'sha256': sha256_file(binary)})
    evidence.observe('workspace', {'path': str(workspace), 'id': workspace_id})
    evidence.observe('surface', args.surface)
    client = MCPClient(binary, config, evidence, args.surface)
    server_exits: list[int] = []
    capability: dict[str, object] = {}
    try:
        with evidence.section('protocol_and_capabilities'):
            initialized = client.initialize()
            evidence.check(initialized.get('protocolVersion') == PROTOCOL_VERSION, 'protocol negotiated')
            instructions = initialized.get('instructions', '')
            evidence.check(isinstance(instructions, str)
                           and 'Operator loop:' in instructions
                           and 'names return exact schemas' in instructions
                           and 'Never nest parents' in instructions,
                           'initialize includes compact operator and discovery guidance')
            listed = client.request('tools/list', {})
            tools = listed.get('tools')
            evidence.check(isinstance(tools, list), 'catalog returned')
            names = {row.get('name') for row in tools if isinstance(row, dict)}
            evidence.check(names == EXPECTED_TOOLS, 'catalog exact', sorted((str(v) for v in names)))
            overview = client.tool('workspace_overview')
            workspaces = overview.get('workspaces')
            evidence.check(isinstance(workspaces, list) and any(isinstance(row, dict) and row.get('workspace_id') == workspace_id for row in workspaces), 'workspace_overview returns the configured workspace', overview)
            workspace_list = client.tool('workspace_list')
            evidence.check(workspace_list == overview, 'workspace_list and workspace_overview agree', workspace_list)
            capability = client.tool('bridge_capabilities')
            expected_surface = 'CHATGPT_DESKTOP_LOCAL' if args.surface == 'desktop-local' else 'CHATGPT_WEB_TUNNEL'
            expected_transport = 'local_stdio' if args.surface == 'desktop-local' else 'outbound_tunnel_stdio'
            expected_architecture = 'single_process' if args.surface == 'desktop-local' else 'single_process_core_plus_outbound_adapter'
            evidence.check(capability.get('chatgpt_mode') == 'CHATGPT_FULL', 'full mode identity', capability)
            evidence.check(capability.get('connector_surface') == expected_surface and capability.get('transport') == expected_transport and capability.get('runtime_architecture') == expected_architecture, 'selected connector identity', capability)
            evidence.check(capability.get('outbound_tunnel_adapter') is (args.surface == 'web-tunnel') and capability.get('public_listener') is False, 'adapter has no public listener', capability)
            evidence.check(capability.get('network_default') == 'loopback_only', 'loopback boundary')
            evidence.check(capability.get('terminal_window_opened') is False, 'no Terminal window')
            evidence.check(capability.get('daemon_used') is False, 'no daemon')
            evidence.check(capability.get('xpc_used') is False, 'no XPC')
            evidence.check(capability.get('keychain_used') is False, 'no Keychain')
            unknown = client.tool('definitely_unknown', expect_error=True)
            evidence.check('error' in unknown, 'unknown tool returns bounded error', unknown)
        with evidence.section('scoped_absolute_path_compatibility'):
            entry = next(row for row in workspaces if row['workspace_id'] == workspace_id)
            evidence.check(entry.get('absolute_paths') is True and 'root_path' not in entry,
                           'scoped workspace advertises absolute spelling without becoming broad')
            read = client.tool('file_read', {'workspace_id': workspace_id, 'path': str(sentinel)})
            evidence.check(read.get('file', {}).get('sha256') == sentinel_hash,
                           'scoped absolute read matches independently hashed file')
            patched = client.tool('file_patch', {'workspace_id': workspace_id, 'path': str(sentinel),
                'old_text': 'sentinel-baseline', 'new_text': 'sentinel-patched', 'expected_sha256': sentinel_hash})
            evidence.check(sentinel.read_bytes() == b'sentinel-patched\n', 'scoped absolute patch observed')
            client.tool('transaction_restore', {'transaction_id': patched['transaction_id']})
            evidence.check(sentinel.read_bytes() == sentinel_bytes, 'scoped absolute patch restored exactly')
            command = client.tool('command_run', {'workspace_id': workspace_id, 'executable': 'sh',
                'arguments': ['-c', 'pwd'], 'cwd': str(workspace), 'timeout_milliseconds': 5000})
            evidence.check(command.get('exit_code') == 0 and command.get('stdout', '').strip() == str(workspace),
                           'absolute cwd resolves within the same scoped workspace')
        with evidence.section('binding_callability_and_cas_acceptance'):
            # Mirrors the real-workload acceptance gate: once capabilities and
            # workspace discovery succeed, the advertised file primitives must
            # remain callable for the rest of the same binding.
            for index in range(100):
                if index % 2 == 0:
                    result = client.tool('file_stat', {
                        'workspace_id': workspace_id, 'path': 'sentinel.txt',
                    })
                    evidence.check(result.get('path', {}).get('sha256') == sentinel_hash,
                                   f'file_stat remains callable at iteration {index + 1}')
                else:
                    result = client.tool('file_read', {
                        'workspace_id': workspace_id, 'path': 'sentinel.txt',
                    })
                    evidence.check(result.get('file', {}).get('sha256') == sentinel_hash,
                                   f'file_read remains callable at iteration {index + 1}')

            cas_transactions: list[str] = []
            initial = client.tool('file_write', {
                'workspace_id': workspace_id,
                'path': 'binding-cas-fixture.txt',
                'content': 'binding-cas-0\n',
                'create_only': True,
            })
            cas_transactions.append(str(initial['transaction_id']))
            current_sha = str(initial['post_sha256'])
            for index in range(1, 21):
                updated = client.tool('file_write', {
                    'workspace_id': workspace_id,
                    'path': 'binding-cas-fixture.txt',
                    'content': f'binding-cas-{index}\n',
                    'expected_sha256': current_sha,
                })
                evidence.check(updated.get('pre_sha256') == current_sha,
                               f'CAS write {index} used the exact current revision')
                current_sha = str(updated['post_sha256'])
                cas_transactions.append(str(updated['transaction_id']))
            evidence.check(sha256_file(workspace / 'binding-cas-fixture.txt') == current_sha,
                           '20 CAS writes match independent filesystem hash')
            for transaction_id in reversed(cas_transactions):
                client.tool('transaction_restore', {'transaction_id': transaction_id})
            evidence.check(not (workspace / 'binding-cas-fixture.txt').exists(),
                           'binding acceptance fixture rolls back without residue')
        with evidence.section('batch_reads_and_completed_status'):
            compact_catalog = client.tool('tool_catalog')
            evidence.check(compact_catalog.get('detail') == 'index'
                           and compact_catalog.get('canonical_count') == len(EXPECTED_TOOLS) - 1
                           and compact_catalog.get('returned_count') == 13
                           and compact_catalog.get('truncated') is True
                           and compact_catalog.get('selection') == 'starter'
                           and not any(row['name'] == 'workspace_list' or 'inputSchema' in row for row in compact_catalog['tools']),
                           'default discovery is compact and excludes duplicate alias')
            catalog = client.tool('tool_catalog', {'detail': 'schemas'})
            evidence.check(catalog.get('tools') == tools and catalog.get('catalog_count') == len(EXPECTED_TOOLS),
                           'expanded catalog matches actual tools/list schemas')
            full_index = client.tool('tool_catalog', {'limit': len(EXPECTED_TOOLS)})
            evidence.check(full_index.get('returned_count') == len(EXPECTED_TOOLS) - 1 and full_index.get('truncated') is False
                           and {row['name'] for row in full_index['tools']} == EXPECTED_TOOLS - {'workspace_list'},
                           'full index still reaches every canonical tool')
            evidence.check('already-loaded' in initialized.get('instructions', '')
                           and 'Available tools (' not in initialized.get('instructions', ''),
                           'initialize gives direct-use discovery guidance without repeated catalog')
            discovery = client.tool('tool_catalog', {'query': 'đọc nhiều file', 'limit': 3})
            evidence.check(discovery['tools'][0]['name'] == 'file_read_many'
                           and len(discovery['tools']) <= 3 and discovery['host_callable_loading_guaranteed'] is False,
                           'bounded Vietnamese discovery ranks batch read without promising host loading')
            schema_subset = client.tool('tool_catalog', {'names': ['file_read_many']})
            evidence.check(schema_subset['tools'] == [row for row in tools if row['name'] == 'file_read_many'],
                           'selected names retain exact-schema compatibility')
            def encoded_size(value):
                return len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
            discovery_sizes = {label: encoded_size(value) for label, value in [
                ('full_schemas_bytes', catalog), ('starter_index_bytes', compact_catalog),
                ('canonical_index_bytes', full_index),
                ('query_top3_bytes', discovery), ('one_schema_bytes', schema_subset)]}
            discovery_sizes['initialize_instructions_bytes'] = len(initialized['instructions'].encode('utf-8'))
            evidence.observe('discovery_payload_bytes', discovery_sizes)
            evidence.check(discovery_sizes['query_top3_bytes'] < discovery_sizes['starter_index_bytes']
                           < discovery_sizes['canonical_index_bytes']
                           < discovery_sizes['full_schemas_bytes'], 'filtered discovery reduces payload')
            evidence.check(discovery_sizes['starter_index_bytes'] <= 8000
                           and discovery_sizes['starter_index_bytes'] < discovery_sizes['full_schemas_bytes'] / 3,
                           'starter response stays inside the bounded payload budget')
            index = client.tool('tool_catalog', {'detail': 'index', 'names': ['command_run', 'command_start']})
            start_schema = next(row for row in index['tools'] if row['name'] == 'command_start')
            evidence.check('timeout_milliseconds' not in start_schema['parameters'], 'background schema excludes synchronous timeout')
            commands = client.tool('command_list')['commands']
            evidence.check(any(row['executable'] == 'git' and row['available'] for row in commands), 'typed executable discovery resolves Git')
            created = client.tool('file_write_many', {'workspace_id': workspace_id, 'files': [
                {'path': 'expanded-a.txt', 'content': 'alpha🙂\r\nbeta\n'},
                {'path': 'expanded-b.txt', 'content': 'alpha🙂\r\nbeta\n'}]})
            evidence.check(
                created['success_count'] == 2
                and created['error_count'] == 0
                and created['batch_atomic'] is False
                and created['all_or_compensated'] is True
                and created['crash_atomic'] is False,
                'batch writes use one undo receipt and honest verified compensation semantics')
            created_ids = [created['transaction_id']]
            lines = client.tool('file_read_lines', {'workspace_id': workspace_id, 'path': 'expanded-a.txt', 'maximum_lines': 1})
            evidence.check(lines['content'] == 'alpha🙂\r\n' and lines['next_line'] == 2 and lines['total_lines'] == 2,
                           'line reading preserves CRLF and cursor')
            tail = client.tool('file_tail', {'workspace_id': workspace_id, 'path': 'expanded-a.txt', 'maximum_bytes': 8})
            evidence.check(tail['content'] == '\r\nbeta\n' and tail['byte_offset'] == 9, 'tail aligns split UTF8 start')
            comparison = client.tool('file_compare', {'workspace_id': workspace_id, 'left_path': 'expanded-a.txt', 'right_path': 'expanded-b.txt'})
            evidence.check(comparison['equal'] is True, 'file comparison matches independent equal fixtures')
            searched = client.tool('file_search_many', {'workspace_id': workspace_id, 'paths': ['expanded-a.txt', 'missing'], 'query': 'beta'})
            evidence.check(searched['results'][0]['matches'][0]['line'] == 2 and searched['results'][1]['status'] == 'error', 'bounded multi-search reports matches and errors')
            summary = client.tool('directory_summary', {'workspace_id': workspace_id})
            evidence.check(summary['complete'] is True and summary['logical_file_bytes'] == len(sentinel_bytes) + 32, 'directory summary agrees with independent file lengths')
            found = client.tool('directory_find', {'workspace_id': workspace_id, 'pattern': 'expanded-?.txt'})
            evidence.check(len(found['matches']) == 2 and found['complete'] is True, 'basename glob finds exact fixture set')
            inspect = client.tool('workspace_inspect', {'workspace_id': workspace_id})
            evidence.check(inspect['access_changed'] is False and inspect['directory']['kind'] == 'directory', 'workspace inspection stays metadata only')
            edited = client.tool('file_apply_edits', {'workspace_id': workspace_id, 'path': 'expanded-a.txt',
                'expected_sha256': sha256_file(workspace / 'expanded-a.txt'),
                'edits': [{'old_text': 'alpha', 'new_text': 'A'}, {'old_text': 'beta', 'new_text': 'B'}]})
            evidence.check((workspace / 'expanded-a.txt').read_bytes() == 'A🙂\r\nB\n'.encode() and edited['edits_applied'] == 2,
                           'multi-edit has actual independent readback')
            client.tool('transaction_restore', {'transaction_id': edited['transaction_id']})
            evidence.check((workspace / 'expanded-a.txt').read_bytes() == (workspace / 'expanded-b.txt').read_bytes(), 'multi-edit undo restores original hash')
            for transaction in reversed(created_ids):
                client.tool('transaction_restore', {'transaction_id': transaction})
            evidence.check(not (workspace / 'expanded-a.txt').exists() and not (workspace / 'expanded-b.txt').exists(), 'expanded batch cleanup removes only created fixtures')
            job = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'cat', 'arguments': []})['task_id']
            waiting = client.tool('process_wait', {'task_id': job, 'maximum_wait_milliseconds': 10})
            evidence.check(waiting['running'] is True and waiting['timed_out'] is False, 'observation timeout never kills a job')
            client.tool('process_input', {'task_id': job, 'content': 'hello🙂END', 'close_stdin': True})
            end = client.tool('process_wait', {'task_id': job})
            evidence.check(end['exit_code'] == 0, 'observed completion succeeds')
            tail = client.tool('process_output_tail', {'task_id': job, 'maximum_bytes_per_stream': 5})
            evidence.check(tail['stdout'] == 'END' and tail['session_retained'] is True, 'process tail is aligned and nonconsuming')
            states = client.tool('process_status_many', {'task_ids': [job, 'invalid']})
            evidence.check(states['results'][0]['result']['exit_code'] == 0 and states['results'][1]['status'] == 'error', 'batch status preserves independent errors')
            drained = client.tool('process_output_many', {'jobs': [{'task_id': job}]})['results'][0]['result']
            evidence.check(drained['stdout'] == 'hello🙂END' and drained['session_retained'] is False, 'batch output full drain releases handle')
            paths = ['sentinel.txt', '.env', 'missing.txt', 'sentinel.txt']
            batch = client.tool('file_read_many', {'workspace_id': workspace_id, 'paths': paths})
            rows = batch.get('results', [])
            evidence.check([r.get('requested_path') for r in rows] == paths, 'batch preserves requested order')
            evidence.check(batch.get('read_count') == 2 and batch.get('error_count') == 2 and batch.get('complete') is False, 'mixed batch reports partial success')
            evidence.check(rows[0].get('file', {}).get('sha256') == sentinel_hash and rows[1].get('error_code') == 'sensitive_path_blocked', 'batch reuses content and sensitive path boundary')
            meta = client.tool('file_stat_many', {'workspace_id': workspace_id, 'paths': ['sentinel.txt']})
            evidence.check(meta.get('complete') is True and 'sha256' not in meta['results'][0]['path'], 'batch metadata avoids content hashing by default')
            meta_hash = client.tool('file_stat_many', {'workspace_id': workspace_id, 'paths': ['sentinel.txt'], 'include_sha256': True})
            evidence.check(meta_hash['results'][0]['path'].get('sha256') == sentinel_hash, 'batch explicit metadata digest matches disk')
            limited = client.tool('file_read_many', {'workspace_id': workspace_id, 'paths': ['sentinel.txt'] * 32, 'maximum_total_bytes': 4})
            evidence.check(limited.get('returned_bytes', 100) <= 4 and limited.get('complete') is False and limited.get('skipped_count', 0) > 0, 'batch enforces shared byte budget')
            invalid = client.tool('file_read_many', {'workspace_id': workspace_id, 'paths': []}, expect_error=True)
            evidence.check('error' in invalid, 'empty batch is rejected')
            started = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'cat', 'arguments': [], 'maximum_output_bytes': 1024})
            task = str(started['task_id'])
            client.tool('process_cancel', {'task_id': task})
            status = client.tool('process_status', {'task_id': task})
            evidence.check(status.get('cancelled') is True and status.get('running') is False and status.get('status_only') is True and status.get('session_retained') is False, 'cancelled status remains queryable without job handle')
            evidence.check('stdout' not in status and 'stderr' not in status and client.tool('process_list').get('processes') == [], 'completed status retains no output or active slot')
            duplicate_cancel = client.tool('process_cancel', {'task_id': task}, expect_error=True)
            evidence.check('error' in duplicate_cancel, 'completed status cannot reauthorize cancellation')
        with evidence.section('file_operations_and_rollback'):
            relative = 'unicøde space.txt'
            baseline = 'alpha🙂\nomega\n'
            created = tool_write(client, workspace_id, relative, baseline)
            created_transaction = str(created['transaction_id'])
            evidence.check((workspace / relative).read_text(encoding='utf-8') == baseline, 'write observed')
            appended = client.tool('file_append', {'workspace_id': workspace_id, 'path': relative, 'content': 'tail🙂\n', 'expected_sha256': sha256_bytes(baseline.encode())})
            appended_transaction = str(appended['transaction_id'])
            appended_text = baseline + 'tail🙂\n'
            rebuilt = read_utf8_file_by_chunks(client, workspace_id, relative, 4)
            evidence.check(rebuilt == appended_text.encode(), 'chunked UTF-8 read exact')
            patched = client.tool('file_patch', {'workspace_id': workspace_id, 'path': relative, 'old_text': 'omega', 'new_text': 'patched', 'replace_all': False, 'expected_sha256': sha256_bytes(appended_text.encode())})
            patched_transaction = str(patched['transaction_id'])
            copied = client.tool('path_copy', {'workspace_id': workspace_id, 'source_path': relative, 'destination_path': 'copied.txt'})
            copied_transaction = str(copied['transaction_id'])
            moved = client.tool('path_move', {'workspace_id': workspace_id, 'source_path': 'copied.txt', 'destination_path': 'moved.txt'})
            moved_transaction = str(moved['transaction_id'])
            stat_result = client.tool('file_stat', {'workspace_id': workspace_id, 'path': 'moved.txt'})
            evidence.check(isinstance(stat_result.get('path'), dict) and stat_result['path'].get('kind') == 'file', 'stat observed moved file')
            for transaction_id in [moved_transaction, copied_transaction, patched_transaction, appended_transaction, created_transaction]:
                client.tool('transaction_restore', {'transaction_id': transaction_id})
            evidence.check(not (workspace / relative).exists(), 'reverse rollback removed created file')
            evidence.check(not (workspace / 'moved.txt').exists(), 'reverse rollback removed copy')
            cleanup_directory = client.tool('directory_create', {'workspace_id': workspace_id, 'path': 'cleanup'})
            cleanup_created = tool_write(client, workspace_id, 'cleanup/remove.txt', 'recoverable')
            removed = client.tool('path_remove', {'workspace_id': workspace_id, 'path': 'cleanup'})
            recovery_path = workspace / str(removed['recovery_path'])
            evidence.check(not (workspace / 'cleanup').exists(), 'recoverable remove observed')
            evidence.check(recovery_path.exists(), 'recovery copy observed')
            client.tool('transaction_restore', {'transaction_id': str(removed['transaction_id'])})
            evidence.check((workspace / 'cleanup/remove.txt').read_text() == 'recoverable', 'recoverable remove restored')
            client.tool('transaction_restore', {'transaction_id': str(cleanup_created['transaction_id'])})
            client.tool('transaction_restore', {'transaction_id': str(cleanup_directory['transaction_id'])})
            evidence.check(not (workspace / '.macbridge').exists(), 'remove recovery has no residue')
            large = run_command(client, workspace_id, 'python3 -c "from pathlib import Path; Path(\'large.bin\').write_bytes(bytes((i % 251 for i in range(1500000))))"')
            evidence.check(large.get('exit_code') == 0, 'large fixture created', large)
            expected_large = bytes((index % 251 for index in range(1500000)))
            rebuilt_large = read_binary_file_by_chunks(client, workspace_id, 'large.bin', 131071)
            evidence.check(sha256_bytes(rebuilt_large) == sha256_bytes(expected_large), 'large binary chunk read exact')
            cursor = 0
            listed_paths: list[str] = []
            for _ in range(100):
                page = client.tool('directory_list', {'workspace_id': workspace_id, 'path': '.', 'recursive': True, 'maximum_entries': 2, 'cursor': cursor})
                entries = page.get('entries')
                if not isinstance(entries, list):
                    raise GateFailure('directory_list omitted entries')
                listed_paths.extend((str(row['relative_path']) for row in entries if isinstance(row, dict) and 'relative_path' in row))
                if page.get('complete') is True:
                    break
                next_cursor = page.get('next_cursor')
                if not isinstance(next_cursor, int) or next_cursor <= cursor:
                    raise GateFailure('directory_list pagination did not advance')
                cursor = next_cursor
            else:
                raise GateFailure('directory_list pagination did not complete')
            evidence.check(len(listed_paths) == len(set(listed_paths)), 'directory pagination has no duplicates')
        with evidence.section('explicit_undo_acceptance'):
            before = client.tool('transaction_list')
            evidence.check(before.get('retained_transaction_count') == 0, 'transaction section starts without retained undo')
            kept = workspace / 'accept-kept.txt'
            kept.write_text('before-accept\n', encoding='utf-8')
            changed = tool_write(client, workspace_id, 'accept-kept.txt', 'after-accept\n', sha256_bytes(b'before-accept\n'))
            other = tool_write(client, workspace_id, 'accept-other.txt', 'other undo\n')
            page = client.tool('transaction_list', {'maximum_transactions': 1})
            owner = page['instance_id']
            a, b = changed['transaction_id'], other['transaction_id']
            evidence.check(page.get('complete') is False and page['transactions'][0]['transaction_id'] == a, 'ordered bounded transaction page')
            evidence.check('before-accept' not in json.dumps(page), 'transaction listing omits previous content')
            client.tool('transaction_accept', {'instance_id': owner, 'transaction_ids': [a, str(uuid.uuid4())]}, expect_error=True)
            client.tool('transaction_accept', {'instance_id': str(uuid.uuid4()), 'transaction_ids': [a]}, expect_error=True)
            evidence.check(client.tool('transaction_list')['retained_transaction_count'] == 2, 'invalid batch or owner releases nothing')
            accepted = client.tool('transaction_accept', {'instance_id': owner, 'transaction_ids': [a]})
            evidence.check(accepted.get('undo_released') is True and accepted.get('released_undo_file_bytes') == len(b'before-accept\n'), 'explicit acceptance releases exact previous bytes')
            evidence.check(accepted.get('filesystem_mutation_performed') is False and kept.read_bytes() == b'after-accept\n', 'accept leaves actual file bytes unchanged')
            readback = client.tool('file_read', {'workspace_id': workspace_id, 'path': 'accept-kept.txt'})
            evidence.check(readback['file']['content'] == 'after-accept\n', 'MCP readback agrees after keeping change')
            rest = client.tool('transaction_list', {'cursor': page['next_cursor']})
            evidence.check([row['transaction_id'] for row in rest['transactions']] == [b], 'cursor does not skip after earlier row accepted')
            client.tool('transaction_restore', {'transaction_id': a}, expect_error=True)
            client.tool('transaction_restore', {'transaction_id': b})
            evidence.check(not (workspace / 'accept-other.txt').exists(), 'unselected undo remains usable')
            removed_file = workspace / 'accept-removal.txt'
            removed_file.write_bytes(b'manual-recovery-fixture\n')
            removed = client.tool('path_remove', {'workspace_id': workspace_id, 'path': 'accept-removal.txt'})
            receipt = client.tool('transaction_accept', {'instance_id': owner, 'transaction_ids': [removed['transaction_id']]})['accepted'][0]
            recovery = workspace / receipt['recovery_path']
            evidence.check(receipt.get('manual_recovery_required') is True and receipt.get('recovery_payload_preserved') is True, 'accepted removal has explicit manual recovery receipt')
            evidence.check(recovery.read_bytes() == b'manual-recovery-fixture\n' and not removed_file.exists(), 'accept never purges removal recovery')
            # Independent manual recovery in this owned fixture only.
            recovery.rename(removed_file)
            recovery.parent.rmdir()
            recovery.parent.parent.rmdir()
            evidence.check(removed_file.read_bytes() == b'manual-recovery-fixture\n', 'retained removal payload is manually recoverable')
            final_undo = client.tool('transaction_list')
            evidence.check(final_undo.get('retained_transaction_count') == 0 and final_undo.get('retained_undo_file_bytes') == 0, 'accept and restore finish with zero retained undo')
        with evidence.section('search_pagination_and_generated_tree_skip'):
            for directory in ['src', '.build', 'vendor']:
                client.tool('directory_create', {'workspace_id': workspace_id, 'path': directory})
            for path in ['src/a.txt', 'src/b.txt']:
                tool_write(client, workspace_id, path, f'needle in {path}\n')
            for path in ['.build/ignored.txt', 'vendor/ignored.txt']:
                tool_write(client, workspace_id, path, 'needle ignored\n')
            cursor = 0
            search_paths: list[str] = []
            for _ in range(20):
                page = client.tool('file_search', {'workspace_id': workspace_id, 'path': '.', 'query': 'needle', 'mode': 'content', 'maximum_results': 1, 'maximum_file_bytes': 2000000, 'cursor': cursor})
                matches = page.get('matches')
                if not isinstance(matches, list):
                    raise GateFailure('file_search omitted matches')
                search_paths.extend((str(row['relative_path']) for row in matches if isinstance(row, dict) and 'relative_path' in row))
                next_cursor = page.get('next_cursor')
                if next_cursor is None:
                    evidence.check(page.get('partial') is True and page.get('skipped_non_utf8_files') == 1
                                   and page.get('complete') is False,
                                   'binary fixture makes content search explicitly partial', page)
                    break
                if not isinstance(next_cursor, int) or next_cursor <= cursor:
                    raise GateFailure('file_search pagination did not advance')
                cursor = next_cursor
            else:
                raise GateFailure('file_search pagination did not complete')
            evidence.check(search_paths == ['src/a.txt', 'src/b.txt'], 'content search is paginated and skips generated trees', search_paths)
            evidence.check(len(search_paths) == len(set(search_paths)), 'search has no duplicates')
            name_search = client.tool('file_search', {'workspace_id': workspace_id, 'path': '.', 'query': 'ignored.txt', 'mode': 'name', 'maximum_results': 10, 'include_ignored': True})
            evidence.check(len(name_search.get('matches', [])) == 2, 'filename search can explicitly include generated trees', name_search)
        with evidence.section('search_budgets_and_serial_admission'):
            # Reuse the small, known src fixtures. No cloud files, permissions,
            # artificial OS hangs, live runtime or private source are involved.
            first_bytes = len('needle in src/a.txt\n'.encode())
            args_search = {'workspace_id': workspace_id, 'path': 'src', 'query': 'needle',
                           'maximum_total_read_bytes': first_bytes}
            partial = client.tool('file_search', args_search)
            evidence.check(partial.get('stop_reason') == 'read_byte_budget'
                           and partial.get('read_bytes') == first_bytes
                           and partial.get('partial') is True and partial.get('complete') is False,
                           'aggregate search budget preserves truthful partial result', partial)
            evidence.check([row['relative_path'] for row in partial['matches']] == ['src/a.txt']
                           and 'next_cursor' not in partial and 'retry_guidance' in partial,
                           'budget stop retains exact matches without inventing a resume cursor')
            args_search['maximum_total_read_bytes'] = first_bytes * 2
            # A new read after each completed response is legitimate, not a
            # blind retry of an ambiguous operation. Exercise lease publication.
            for _ in range(32):
                full = client.tool('file_search', args_search)
                if full.get('complete') is not True or len(full.get('matches', [])) != 2:
                    raise GateFailure(f'sequential search lost completeness: {full}')
            evidence.check(full.get('read_bytes') == first_bytes * 2,
                           '32 sequential completed searches have exact bytes and no stale busy lease')
            names_only = client.tool('file_search', {**args_search, 'mode': 'name',
                                     'query': '.txt', 'maximum_total_read_bytes': 1})
            evidence.check(names_only.get('read_bytes') == 0 and names_only.get('complete') is True
                           and len(names_only.get('matches', [])) == 2,
                           'name-only search does not spend content read budget')
            rejected = client.tool('file_search', {**args_search,
                                   'maximum_duration_milliseconds': 10_001}, expect_error=True)
            evidence.check('error' in rejected, 'invalid cooperative budget is rejected')
            state = client.tool('bridge_capabilities')
            evidence.check(state.get('active_searches') == 0 and state.get('maximum_concurrent_searches') == 1,
                           'search completion releases the single admission slot')
        with evidence.section('non_swift_development_fail_fix_pass_rollback'):
            tool_write(client, workspace_id, '.gitignore', '.macbridge/\n.build/\nnode_modules/\n')
            tool_write(client, workspace_id, 'package.json', json.dumps({'name': 'macbridge-e2e-project', 'private': True, 'scripts': {'build': 'node --check sum.js', 'test': 'node --test sum.test.js'}}, sort_keys=True) + '\n')
            broken_source = 'exports.sum = (a, b) => a - b;\n'
            fixed_source = 'exports.sum = (a, b) => a + b;\n'
            tool_write(client, workspace_id, 'sum.js', broken_source)
            tool_write(client, workspace_id, 'sum.test.js', "const test = require('node:test');\nconst assert = require('node:assert/strict');\nconst { sum } = require('./sum.js');\ntest('sum', () => assert.equal(sum(2, 3), 5));\n")
            toolchains = run_command(client, workspace_id, 'for tool in git python3 node npm ruby swift make; do tool_path=$(command -v "$tool") || exit 91; printf \'TOOL:%s:%s:\' "$tool" "$tool_path"; "$tool" --version 2>&1 | head -n 1; done')
            evidence.check(toolchains.get('exit_code') == 0, 'installed toolchains discovered', toolchains)
            for tool in ['git', 'python3', 'node', 'npm', 'ruby', 'swift', 'make']:
                evidence.check(f'TOOL:{tool}:' in str(toolchains.get('stdout', '')), f'{tool} discovered')
            build = run_command(client, workspace_id, 'npm run build')
            evidence.check(build.get('exit_code') == 0, 'Node build passes', build)
            failing = run_command(client, workspace_id, 'npm test')
            evidence.check(failing.get('exit_code') != 0, 'intentional Node test fails', failing)
            fixed = client.tool('file_patch', {'workspace_id': workspace_id, 'path': 'sum.js', 'old_text': broken_source, 'new_text': fixed_source, 'replace_all': False, 'expected_sha256': sha256_bytes(broken_source.encode())})
            passing = run_command(client, workspace_id, 'npm test')
            evidence.check(passing.get('exit_code') == 0, 'MCP fix makes Node test pass', passing)
            client.tool('transaction_restore', {'transaction_id': str(fixed['transaction_id'])})
            rolled_back = run_command(client, workspace_id, 'npm test')
            evidence.check(rolled_back.get('exit_code') != 0, 'fix rollback restores failing baseline')
            pipeline = run_command(client, workspace_id, "printf 'pipe-ok\\n' | tr a-z A-Z")
            evidence.check(pipeline.get('exit_code') == 0 and 'PIPE-OK' in str(pipeline.get('stdout', '')), 'headless shell pipe works', pipeline)
        with evidence.section('disposable_git_workflow'):
            initialized_git = run_command(client, workspace_id, "git init -b main && git config user.name 'MacBridge E2E' && git config user.email 'macbridge-e2e@invalid.example' && git add . && git commit -m 'baseline'")
            evidence.check(initialized_git.get('exit_code') == 0, 'Git init/add/commit passes', initialized_git)
            clean = run_command(client, workspace_id, 'git status --porcelain')
            evidence.check(clean.get('exit_code') == 0 and clean.get('stdout') == '', 'Git status clean')
            branch = run_command(client, workspace_id, 'git switch -c e2e-branch')
            evidence.check(branch.get('exit_code') == 0, 'Git branch created', branch)
            # This edit predates the task mutation; no commit/reset/discard may consume it.
            sentinel.write_bytes(b'preexisting user edit\n')
            dirty_before = run_command(client, workspace_id, 'git status --porcelain && git diff -- sentinel.txt')
            index_before = sha256_file(workspace / '.git/index')
            for name, extra in [
                ('git_status', {}), ('git_diff', {'path': 'sentinel.txt'}),
                ('git_log', {'maximum_commits': 1}), ('git_show', {}),
                ('git_branches', {}), ('git_worktrees', {}),
                ('git_blame', {'path': 'sentinel.txt', 'maximum_lines': 1}),
                ('git_file_list', {'include_untracked': True})]:
                response = client.tool(name, {'workspace_id': workspace_id, **extra})
                evidence.check(response.get('exit_code') == 0 and response.get('process_started') is True,
                               f'{name} executes typed Git operation', response)
                if name == 'git_diff':
                    evidence.check('preexisting user edit' in response['stdout'], 'typed Git diff reflects real dirty file')
                if name == 'git_file_list':
                    evidence.check('sentinel.txt' in response['stdout'].split('\0'), 'typed file list preserves NUL framing')
            evidence.check(sha256_file(workspace / '.git/index') == index_before, 'typed read-only Git tools leave index unchanged')
            client.tool('git_log', {'workspace_id': workspace_id, 'revision': '--all'}, expect_error=True)
            client.tool('git_blame', {'workspace_id': workspace_id, 'path': '../outside'}, expect_error=True)
            note = tool_write(client, workspace_id, 'git-note.txt', 'branch change\n')
            dirty = run_command(client, workspace_id, 'git status --short && git diff -- sentinel.txt')
            evidence.check('git-note.txt' in str(dirty.get('stdout', '')) and
                           'preexisting user edit' in str(dirty.get('stdout', '')),
                           'Git status/diff observes task and preexisting changes', dirty)
            client.tool('transaction_restore', {'transaction_id': str(note['transaction_id'])})
            dirty_after = run_command(client, workspace_id, 'git status --porcelain && git diff -- sentinel.txt')
            evidence.check(dirty_after.get('exit_code') == 0 and dirty_after.get('stdout') == dirty_before.get('stdout')
                           and sentinel.read_bytes() == b'preexisting user edit\n',
                           'task rollback preserves exact preexisting Git diff', dirty_after)
            sentinel.write_bytes(sentinel_bytes) # fixture teardown only, after preservation oracle
            evidence.check('remote' not in (workspace / '.git/config').read_text(encoding='utf-8'), 'Git fixture has no remote and cannot push')
        with evidence.section('mb_operator_parent_gateway_and_evidence'):
            inspected = client.tool('developer_inspect', {
                'action': 'inspect_repo', 'workspace_id': workspace_id,
                'maximum_commits': 2,
            })
            evidence.check(inspected.get('authority_changed') is False
                           and inspected.get('git_status', {}).get('exit_code') == 0,
                           'operator inspection is read-only and returns Git context')

            parent = client.tool('work_task', {
                'action': 'begin', 'title': 'Verify MB Operator fixture',
                'chat_label': 'synthetic-e2e', 'workspace_id': workspace_id,
            })
            work_id = str(parent['work_id'])
            before = sha256_file(workspace / 'sum.js')
            observed = client.tool('file_read', {
                'workspace_id': workspace_id, 'path': 'sum.js', 'work_id': work_id,
            })
            evidence.check(observed['file']['sha256'] == before,
                           'operator inspection hash matches independent baseline')
            fixed = client.tool('file_patch', {
                'workspace_id': workspace_id, 'path': 'sum.js',
                'old_text': broken_source, 'new_text': fixed_source,
                'replace_all': False, 'expected_sha256': before, 'work_id': work_id,
            })
            reviewed = client.tool('developer_inspect', {
                'action': 'review_diff', 'workspace_id': workspace_id,
                'path': 'sum.js', 'work_id': work_id,
            })
            evidence.check(reviewed.get('authority_changed') is False
                           and fixed_source.strip() in reviewed.get('git_diff', {}).get('stdout', ''),
                           'operator diff review sees the exact applied change')
            test_job = client.tool('command_start', {
                'workspace_id': workspace_id, 'executable': 'zsh',
                'arguments': ['-f', '-c', 'exec node --test sum.test.js'],
                'work_id': work_id,
            })
            test_id = str(test_job['task_id'])
            wait_stopped(client, test_id)
            test_result = client.tool('process_output', {
                'task_id': test_id, 'work_id': work_id,
            })
            evidence.check(test_result.get('exit_code') == 0
                           and test_result.get('session_retained') is False,
                           'operator verification test passes and releases its handle')
            client.tool('transaction_restore', {
                'transaction_id': str(fixed['transaction_id']), 'work_id': work_id,
            })
            restored = client.tool('file_read', {
                'workspace_id': workspace_id, 'path': 'sum.js', 'work_id': work_id,
            })
            evidence.check(restored['file']['sha256'] == before
                           and sha256_file(workspace / 'sum.js') == before,
                           'operator rollback has MCP and independent hash evidence')
            finished = client.tool('work_task', {
                'action': 'finish', 'work_id': work_id, 'status': 'completed',
            })
            evidence.check(finished.get('state') == 'completed',
                           'specialist operator parent finishes explicitly')

            gateway = client.tool('developer_task', {
                'action': 'execute_task', 'workspace_id': workspace_id,
                'title': 'Check fixture syntax', 'chat_label': 'synthetic-e2e',
                'executable': 'zsh',
                'arguments': ['-f', '-c', 'exec node --check sum.js'],
            })
            gateway_id = str(gateway['workflow_id'])
            for _ in range(100):
                continued = client.tool('developer_task', {
                    'action': 'continue_task', 'workflow_id': gateway_id,
                })
                if continued.get('workflow_terminal') is True:
                    break
                time.sleep(0.01)
            else:
                raise GateFailure('developer execute_task did not finish')
            evidence.check(continued.get('workflow_terminal_status') == 'completed'
                           and continued.get('exit_code') == 0,
                           'developer execute_task owns one parent and completes through continue_task')

            failing_gateway = client.tool('developer_task', {
                'action': 'run_tests', 'workspace_id': workspace_id,
                'title': 'Confirm failing baseline', 'test_kind': 'custom',
                'executable': 'zsh',
                'arguments': ['-f', '-c', 'exec node --test sum.test.js'],
            })
            failing_gateway_id = str(failing_gateway['workflow_id'])
            for _ in range(100):
                failed_continuation = client.tool('developer_task', {
                    'action': 'continue_task', 'workflow_id': failing_gateway_id,
                })
                if failed_continuation.get('workflow_terminal') is True:
                    break
                time.sleep(0.01)
            else:
                raise GateFailure('developer run_tests did not finish')
            evidence.check(failed_continuation.get('workflow_terminal_status') == 'failed'
                           and failed_continuation.get('exit_code') != 0,
                           'developer run_tests reports a real failing test without false completion')
            evidence.check(client.tool('process_list').get('processes') == [],
                           'operator fixture leaves no retained process handle')

        with evidence.section('persistent_shell_python_node_and_process_lifecycle'):
            shell = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'zsh', 'arguments': ['-f'], 'cwd': '.', 'maximum_output_bytes': 65536})
            shell_id = str(shell['task_id'])
            send_process_bytes(client, shell_id, b'export MB_E2E_STATE=kept\nmkdir -p session-cwd\ncd session-cwd\nprintf \'SHELL-STATE:%s:%s\\n\' "$MB_E2E_STATE" "$PWD"\n')
            shell_output = wait_output_contains(client, shell_id, 'SHELL-STATE:kept:')
            evidence.check('/session-cwd' in str(shell_output.get('stdout', '')), 'shell cwd and env persist')
            send_process_bytes(client, shell_id, b'exit\n', close_stdin=True)
            wait_stopped(client, shell_id)
            read_process_output(client, shell_id)
            python = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'python3', 'arguments': ['-u', '-i'], 'cwd': '.', 'maximum_output_bytes': 65536})
            python_id = str(python['task_id'])
            send_process_bytes(client, python_id, b"value = 41\nprint('PYTHON-STATE:' + str(value + 1), flush=True)\n")
            wait_output_contains(client, python_id, 'PYTHON-STATE:42')
            send_process_bytes(client, python_id, b'exit()\n', close_stdin=True)
            wait_stopped(client, python_id)
            read_process_output(client, python_id)
            node = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'zsh', 'arguments': ['-f', '-c', 'exec node -i'], 'cwd': '.', 'maximum_output_bytes': 65536})
            node_id = str(node['task_id'])
            send_process_bytes(client, node_id, b"let value = 41\nconsole.log('NODE-STATE:' + (value + 1))\n")
            wait_output_contains(client, node_id, 'NODE-STATE:42')
            send_process_bytes(client, node_id, b'.exit\n', close_stdin=True)
            wait_stopped(client, node_id)
            read_process_output(client, node_id)
            timeout = run_command(client, workspace_id, 'sleep 2', timeout_ms=200)
            evidence.check(timeout.get('timed_out') is True, 'synchronous timeout enforced', timeout)
            long_job = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'sleep', 'arguments': ['30'], 'cwd': '.', 'maximum_output_bytes': 1024})
            long_job_id = str(long_job['task_id'])
            evidence.check(client.tool('process_status', {'task_id': long_job_id}).get('running') is True, 'long command exposes pollable job')
            cancelled = client.tool('process_cancel', {'task_id': long_job_id})
            evidence.check(cancelled.get('cancelled') is True, 'job cancellation enforced', cancelled)
            tail = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'zsh', 'arguments': ['-f', '-c', 'printf BEGIN; i=0; while [ $i -lt 300 ]; do printf x; i=$((i+1)); done; printf TAIL-MARKER'], 'cwd': '.', 'maximum_output_bytes': 64})
            tail_id = str(tail['task_id'])
            wait_stopped(client, tail_id)
            tail_output = read_process_output(client, tail_id)
            evidence.check(str(tail_output.get('stdout', '')).endswith('TAIL-MARKER'), 'newest output tail retained')
            evidence.check(tail_output.get('stdout_cursor_adjusted') is True, 'dropped cursor is explicit')
        with evidence.section('streaming_utf8_and_hard_retention'):
            tiny = run_command(client, workspace_id, "printf '🙂'", maximum_output_bytes=1)
            evidence.check(tiny.get('exit_code') == 0 and tiny.get('stdout') == ''
                           and tiny.get('stdout_total_bytes') == 4
                           and tiny.get('stdout_dropped_bytes') == 4
                           and tiny.get('stdout_truncated') is True,
                           'retention cap never expands to fit a UTF8 scalar', tiny)
            for stream, command in [('stdout', 'cat'), ('stderr', 'cat >&2')]:
                job = client.tool('command_start', {'workspace_id': workspace_id,
                    'executable': 'sh', 'arguments': ['-c', command],
                    'maximum_output_bytes': 1024})['task_id']
                send_process_bytes(client, job, bytes([0x41, 0xF0, 0x9F]))
                deadline = time.monotonic() + 2
                while True:
                    state = client.tool('process_status', {'task_id': job})
                    if state.get(stream + '_total_bytes') == 3:
                        break
                    if time.monotonic() >= deadline:
                        raise GateFailure('split UTF8 fixture prefix did not arrive')
                    time.sleep(0.01)
                first = read_process_output(client, job)
                evidence.check(first.get(stream) == 'A' and first.get(stream + '_next_cursor') == 1
                               and first.get('running') is True,
                               f'{stream} streaming cursor waits for complete scalar', first)
                tail = client.tool('process_output_tail', {'task_id': job})
                evidence.check(tail.get(stream) == 'A' and tail.get(stream + '_next_cursor') == 1,
                               f'{stream} live peek does not expose incomplete scalar', tail)
                send_process_bytes(client, job, bytes([0x99, 0x82, 0x42]), close_stdin=True)
                wait_stopped(client, job)
                last = read_process_output(client, job, first['stdout_next_cursor'], first['stderr_next_cursor'])
                evidence.check(last.get(stream) == '🙂B' and last.get(stream + '_next_cursor') == 6
                               and last.get('exit_code') == 0 and last.get('session_retained') is False,
                               f'{stream} streaming cursor resumes exactly and drains handle', last)
            evidence.check(client.tool('process_list').get('processes') == [],
                           'streaming fixtures leave no tracked process')
        with evidence.section('localhost_development_server_reload_and_stop'):
            tool_write(client, workspace_id, 'served.txt', 'version-one')
            server_script = "import http.server\nclass Handler(http.server.BaseHTTPRequestHandler):\n    def do_GET(self):\n        content = open('served.txt', 'rb').read()\n        self.send_response(200)\n        self.send_header('Content-Length', str(len(content)))\n        self.end_headers()\n        self.wfile.write(content)\n    def log_message(self, format, *args):\n        pass\nserver = http.server.HTTPServer(('127.0.0.1', 0), Handler)\nprint('PORT:' + str(server.server_port), flush=True)\nserver.serve_forever()\n"
            tool_write(client, workspace_id, 'server.py', server_script)
            server = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'python3', 'arguments': ['server.py'], 'cwd': '.', 'maximum_output_bytes': 65536})
            server_id = str(server['task_id'])
            server_output = wait_output_contains(client, server_id, 'PORT:')
            port_line = next((line for line in str(server_output.get('stdout', '')).splitlines() if line.startswith('PORT:')))
            port = int(port_line.split(':', 1)[1])
            evidence.check(fetch_loopback(port) == b'version-one', 'loopback dev server responds')
            served_patch = client.tool('file_patch', {'workspace_id': workspace_id, 'path': 'served.txt', 'old_text': 'version-one', 'new_text': 'version-two', 'replace_all': False, 'expected_sha256': sha256_bytes(b'version-one')})
            evidence.check(fetch_loopback(port) == b'version-two', 'dev server reload observes file change')
            client.tool('process_cancel', {'task_id': server_id})
            client.tool('transaction_restore', {'transaction_id': str(served_patch['transaction_id'])})
            external = run_command(client, workspace_id, 'python3 -c "import socket; socket.socket().connect((\'192.0.2.1\', 9))"', timeout_ms=2000)
            evidence.check(external.get('exit_code') != 0 and 'Operation not permitted' in str(external.get('stderr', '')), 'non-loopback network remains denied', external)
        with evidence.section('workspace_reload_reconnect_and_finite_stress'):
            second_workspace = root / 'workspace-two'
            second_workspace.mkdir()
            second_id = str(uuid.uuid4())
            write_configuration(config, [(workspace_id, 'e2e-workspace', workspace), (second_id, 'e2e-workspace-two', second_workspace)])
            refused = client.tool('workspace_reload', expect_error=True)
            evidence.check('undo transactions' in str(refused), 'reload refuses pending undo without discarding it', refused)
            for transaction_id in reversed(client.pending_transactions.copy()):
                client.tool('transaction_restore', {'transaction_id': transaction_id})
            reloaded = client.tool('workspace_reload')
            evidence.check(len(reloaded.get('workspaces', [])) == 2, 'workspace allowlist reloads')
            write_configuration(config, [(workspace_id, 'e2e-workspace', workspace)])
            reloaded_back = client.tool('workspace_reload')
            evidence.check(len(reloaded_back.get('workspaces', [])) == 1, 'workspace reload reverses')
            for _ in range(10):
                quick = client.tool('command_start', {'workspace_id': workspace_id, 'executable': 'true', 'arguments': [], 'cwd': '.', 'maximum_output_bytes': 1024})
                quick_id = str(quick['task_id'])
                wait_stopped(client, quick_id)
                read_process_output(client, quick_id)
            processes = client.tool('process_list')
            evidence.check(processes.get('processes') == [], 'finite stress leaves no tracked process')
            evidence.check(not (workspace / '.macbridge').exists(), 'finite stress leaves no runtime residue')
            first_exit = client.close()
            server_exits.append(first_exit)
            evidence.check(first_exit == 0, 'first MCP process exits cleanly')
            client = MCPClient(binary, config, evidence, args.surface)
            restarted = client.initialize()
            evidence.check(restarted.get('protocolVersion') == PROTOCOL_VERSION, 'MCP reconnect negotiates')
            restarted_capability = client.tool('bridge_capabilities')
            evidence.check(restarted_capability.get('mcp_executable_sha256') == capability.get('mcp_executable_sha256'), 'restart uses identical binary')
            sentinel_read = client.tool('file_read', {'workspace_id': workspace_id, 'path': 'sentinel.txt'})
            evidence.check(isinstance(sentinel_read.get('file'), dict) and sentinel_read['file'].get('sha256') == sentinel_hash, 'sentinel survives reconnect unchanged')
            invalid_restore = client.tool('transaction_restore', {'transaction_id': str(uuid.uuid4())}, expect_error=True)
            evidence.check('error' in invalid_restore, 'unknown rollback after restart is explicit')
        with evidence.section('explicit_broad_filesystem_absolute_paths_and_rollback'):
            broad_id = str(uuid.uuid4())
            write_configuration(config, [(workspace_id, 'e2e-workspace', workspace)], broad_id=broad_id)
            reloaded = client.tool('workspace_reload')
            broad = next((row for row in reloaded.get('workspaces', []) if row.get('workspace_id') == broad_id), {})
            evidence.check(broad.get('root_path') == '/' and broad.get('absolute_paths') is True, 'broad root explicitly advertised')
            broad_caps = client.tool('bridge_capabilities')
            evidence.check(broad_caps.get('broad_filesystem_access') is True and broad_caps.get('credential_paths_blocked') is True, 'broad access retains credential exclusion')
            evidence.check(broad_caps.get('mcp_executable_sha256') == capability.get('mcp_executable_sha256'), 'broad access uses same binary')
            # All mutations stay inside this test-owned temporary directory,
            # but outside the original registered workspace.
            absolute_parent = root.resolve() / 'outside-workspace'
            target = str(absolute_parent / 'notes.txt')
            baseline = 'broad baseline\n'
            transactions = []
            directory = client.tool('directory_create', {'workspace_id': broad_id, 'path': str(absolute_parent)})
            transactions.append(str(directory['transaction_id']))
            created = tool_write(client, broad_id, target, baseline)
            transactions.append(str(created['transaction_id']))
            evidence.check(created.get('backend_called') is True and created.get('mutation_performed') is True and Path(target).read_text() == baseline, 'absolute write independently observed outside project')
            read = client.tool('file_read', {'workspace_id': broad_id, 'path': target})
            evidence.check(read.get('file', {}).get('content') == baseline, 'absolute read roundtrip')
            appended = client.tool('file_append', {'workspace_id': broad_id, 'path': target, 'content': 'tail\n', 'expected_sha256': sha256_bytes(baseline.encode())})
            transactions.append(str(appended['transaction_id']))
            patched = client.tool('file_patch', {'workspace_id': broad_id, 'path': target, 'old_text': 'baseline', 'new_text': 'patched', 'expected_sha256': sha256_bytes((baseline + 'tail\n').encode())})
            transactions.append(str(patched['transaction_id']))
            expected = 'broad patched\ntail\n'
            evidence.check(Path(target).read_text() == expected, 'absolute append and patch observed')
            stat_result = client.tool('file_stat', {'workspace_id': broad_id, 'path': target})
            evidence.check(stat_result.get('path', {}).get('sha256') == sha256_bytes(expected.encode()), 'absolute stat digest matches')
            listed = client.tool('directory_list', {'workspace_id': broad_id, 'path': str(absolute_parent)})
            evidence.check(len(listed.get('entries', [])) == 1, 'absolute directory listing')
            searched = client.tool('file_search', {'workspace_id': broad_id, 'path': str(absolute_parent), 'query': 'broad patched'})
            evidence.check(len(searched.get('matches', [])) == 1, 'absolute content search')
            copied = client.tool('path_copy', {'workspace_id': broad_id, 'source_path': target, 'destination_path': str(absolute_parent / 'copy.txt')})
            transactions.append(str(copied['transaction_id']))
            moved = client.tool('path_move', {'workspace_id': broad_id, 'source_path': str(absolute_parent / 'copy.txt'), 'destination_path': str(absolute_parent / 'moved.txt')})
            transactions.append(str(moved['transaction_id']))
            removed = client.tool('path_remove', {'workspace_id': broad_id, 'path': str(absolute_parent / 'moved.txt')})
            transactions.append(str(removed['transaction_id']))
            recovery = Path('/') / str(removed['recovery_path'])
            evidence.check(recovery.is_relative_to(absolute_parent / '.macbridge/recovery') and recovery.read_text() == expected, 'absolute remove keeps same-volume recovery')
            command = client.tool('command_run', {'workspace_id': broad_id, 'executable': 'zsh', 'arguments': ['-f', '-c', "printf 'broad-command-ok' > command.txt; cat notes.txt"], 'cwd': str(absolute_parent), 'timeout_milliseconds': 5000})
            evidence.check(command.get('exit_code') == 0 and command.get('terminal_window_opened') is False and command.get('stdout') == expected, 'headless command reads outside original workspace')
            evidence.check((absolute_parent / 'command.txt').read_text() == 'broad-command-ok', 'headless command write independently observed')
            cleanup_command = client.tool('command_run', {'workspace_id': broad_id, 'executable': 'zsh', 'arguments': ['-f', '-c', 'rm command.txt'], 'cwd': str(absolute_parent), 'timeout_milliseconds': 5000})
            evidence.check(cleanup_command.get('exit_code') == 0 and not (absolute_parent / 'command.txt').exists(), 'headless command test file removed')
            for transaction_id in reversed(transactions):
                restored = client.tool('transaction_restore', {'transaction_id': transaction_id})
                evidence.check(restored.get('mutation_performed') is True, 'broad rollback applied')
            evidence.check(not absolute_parent.exists(), 'absolute workflow rollback leaves no test or recovery residue')
            evidence.check(client.tool('process_list').get('processes') == [], 'broad workflow has no tracked process')
            write_configuration(config, [(workspace_id, 'e2e-workspace', workspace)])
            client.tool('workspace_reload')
            evidence.check(client.tool('bridge_capabilities').get('broad_filesystem_access') is False, 'broad opt-in can be removed by config reload')
    except Exception:
        raise
    finally:
        if client.process.poll() is None:
            server_exits.append(client.close())
    sentinel_after = sha256_file(sentinel) if sentinel.exists() else None
    evidence.check(sentinel_after == sentinel_hash, 'final sentinel hash unchanged')
    return {'capabilities': capability, 'server_exits': server_exits, 'sentinel_sha256_before': sentinel_hash, 'sentinel_sha256_after': sha256_file(sentinel) if sentinel.exists() else None}

def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, help='Exact macbridge-mcp artifact to test')
    parser.add_argument('--evidence-dir', required=True, help='New directory for raw evidence')
    parser.add_argument('--surface', choices=('desktop-local', 'web-tunnel'), default='desktop-local', help='Capability surface reported by the same functional core')
    parser.add_argument('--work-parent', help='Optional parent for the disposable workspace')
    parser.add_argument('--keep-workspace', action='store_true', help='Keep disposable state for debugging')
    return parser.parse_args()

def main() -> int:
    args = parse_arguments()
    evidence_directory = Path(args.evidence_dir).expanduser().resolve()
    if evidence_directory.exists():
        print(f'evidence directory already exists: {evidence_directory}', file=sys.stderr)
        return 64
    work_parent = Path(args.work_parent).expanduser().resolve() if args.work_parent else None
    if work_parent is not None:
        work_parent.mkdir(parents=True, exist_ok=True)
    evidence = Evidence(evidence_directory)
    # The server stores the realpath spelling of each workspace root. Resolve
    # macOS /var and /tmp aliases here so the absolute-path gate exercises that
    # documented canonical spelling instead of failing in fixture preparation.
    root = Path(tempfile.mkdtemp(prefix='macbridge-local-e2e-', dir=work_parent)).resolve()
    (root / '.macbridge-e2e-owned').write_text('owned by run_local_e2e.py\n', encoding='utf-8')
    started = time.monotonic()
    result: dict[str, object] = {}
    failure: str | None = None
    try:
        result = run_gate(args, evidence, root)
    except Exception as error:
        failure = f'{type(error).__name__}: {error}'
        evidence.observe('failure', failure)
    finally:
        result['checks'] = evidence.check_count
        result['sections'] = evidence.sections
        result['elapsed_ms'] = int((time.monotonic() - started) * 1000)
        result['workspace_retained'] = args.keep_workspace
        result['workspace_path'] = str(root) if args.keep_workspace else None
        if not args.keep_workspace:
            marker = root / '.macbridge-e2e-owned'
            if root.name.startswith('macbridge-local-e2e-') and marker.is_file():
                shutil.rmtree(root)
            else:
                failure = failure or 'refused to remove unverified disposable workspace'
        result['status'] = 'PASS' if failure is None else 'FAIL'
        result['failure'] = failure
        (evidence.directory / 'summary.json').write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False))
    return 0 if failure is None else 1
if __name__ == '__main__':
    raise SystemExit(main())
