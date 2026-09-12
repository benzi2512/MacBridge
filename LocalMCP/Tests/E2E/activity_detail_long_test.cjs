'use strict';
// Reviewed, dependency-free fixture. No production config, credentials, GUI or network.
// A timed 24-second validation task demonstrates multiple *real* returned receipts;
// this is not a normal Chat rendering test or a performance benchmark.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const readline = require('node:readline');
const assert = require('node:assert/strict');
const binary = fs.realpathSync(process.argv[2]);
const expectedHash = process.argv[3];
const evidenceFile = process.argv[4];
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
assert.match(expectedHash, /^[0-9a-f]{64}$/);
assert.equal(sha(fs.readFileSync(binary)), expectedHash, 'execute the exact reviewed artifact');
const root = fs.mkdtempSync('/private/tmp/mb-activity-detail-');
const workspace = path.join(root, 'workspace');
fs.mkdirSync(workspace, {mode: 0o700});
const workspaceID = '11111111-2222-4333-8444-555555555555';
const config = path.join(root, 'workspaces.json');
fs.writeFileSync(config, JSON.stringify({version: 1, workspaces: [
  {id: workspaceID, name: 'Activity detail fixture', path: workspace}
]}), {mode: 0o600});
const original = 'def add(a, b):\n    return a - b\n';
fs.writeFileSync(path.join(workspace, 'sum.py'), original);
fs.writeFileSync(path.join(workspace, 'test_long.py'), [
  'import sys, time', 'from sum import add',
  'for step in range(12):',
  '    for n in range(10000):',
  '        assert add(n, 7) == n + 7',
  '    print("VALIDATED_BATCH_" + str(step + 1), flush=True)',
  '    if step == 5: print("PRIVATE_STDERR_CANARY", file=sys.stderr, flush=True)',
  '    time.sleep(2)',
  'print("FIXTURE_ACCEPTANCE_OK", flush=True)', ''
].join('\n'));
const child = spawn(binary, ['--config', config, '--surface', 'web-tunnel'], {
  env: {PATH: '/usr/bin:/bin', TMPDIR: root}, stdio: ['pipe', 'pipe', 'pipe']
});
let sequence = 0, stderr = '', exited = false, job, jobToken, transaction, transactionToken;
const pending = new Map(), receipts = [];
const exit = new Promise(resolve => child.once('exit', code => {
  exited = true;
  for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error('owner exited')); }
  pending.clear(); resolve(code);
}));
child.stderr.on('data', data => { stderr = (stderr + data).slice(-4096); });
readline.createInterface({input: child.stdout}).on('line', line => {
  const response = JSON.parse(line), request = pending.get(response.id);
  if (!request) return;
  pending.delete(response.id); clearTimeout(request.timer);
  if (response.error) request.reject(new Error(JSON.stringify(response.error)));
  else request.resolve(response.result);
});
function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('RPC timeout ' + method + ' ' + stderr)); }, 15000);
    pending.set(id, {resolve, reject, timer});
    child.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
  });
}
async function tool(name, args = {}) {
  const result = await rpc('tools/call', {name, arguments: args});
  assert.equal(result.isError, false, JSON.stringify(result));
  const text = result.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
  assert(!text.includes('PRIVATE_STDERR_CANARY'), 'raw output is not copied into labels');
  assert(!text.includes('PRIVATE_SCRIPT_CANARY'), 'inline script is not copied into labels');
  receipts.push({call: sequence, name, text});
  return {data: result.structuredContent, text};
}
(async () => {
  const started = Date.now();
  try {
    const catalog = await rpc('tools/list');
    assert.equal(catalog.tools.length, 72, 'combined desktop candidate catalog');
    // The detail gate must preserve this reviewed release candidate's catalog.
    assert.equal(catalog.catalogEpoch, '0725dab73d8abb6739a6785f5af4a0e2e7e55807a86c7f7e23cd62f1aafb85ca');
    const caps = await tool('bridge_capabilities');
    assert.equal(caps.data.mcp_executable_sha256, expectedHash);
    assert(caps.text.includes('72 catalog tools'));
    assert.equal(caps.data.desktop_open_enabled, false);
    assert.equal(caps.data.computer_grants_configured, 0);
    const read = await tool('file_read_lines', {workspace_id: workspaceID, path: 'sum.py', start_line: 1, maximum_lines: 2});
    assert(read.text.includes('target sum.py'));
    assert(read.text.includes('Read 2 lines (1–2)'));
    const failed = await tool('command_run', {workspace_id: workspaceID, executable: 'python3', arguments: ['-B', 'test_long.py'], cwd: '.', timeout_milliseconds: 10000});
    assert.notEqual(failed.data.exit_code, 0, 'real baseline fails');
    assert(failed.text.includes('command python3 -B test_long.py'));
    assert(failed.text.includes('Process exited with code 1'));
    const patched = await tool('file_apply_edits', {workspace_id: workspaceID, path: 'sum.py', expected_sha256: sha(original), edits: [
      {old_text: 'return a - b', new_text: 'return a + b'}
    ]});
    transaction = patched.data.transaction_id;
    transactionToken = patched.data.transaction_control_token;
    assert(transaction);
    assert(transactionToken);
    assert(patched.text.includes('1 edits applied'));
    const start = await tool('developer_task', {action: 'run_tests', test_kind: 'custom', workspace_id: workspaceID,
      title: 'Verify activity receipts with a long task', executable: 'python3', arguments: ['-B', 'test_long.py'], cwd: '.', maximum_output_bytes: 8192});
    job = start.data.task_id;
    jobToken = start.data.process_control_token;
    const workflow = start.data.workflow_id;
    const workflowToken = start.data.work_control_token;
    assert(jobToken);
    assert(workflowToken);
    assert(start.text.includes('command python3 -B test_long.py'));
    let final, observedRunning = 0;
    const produced = [], elapsed = [];
    for (let i = 0; i < 8; i++) {
      await new Promise(resolve => setTimeout(resolve, 4000));
      const step = await tool('developer_task', {action: 'continue_task', workflow_id: workflow,
        work_control_token: workflowToken, process_control_token: jobToken});
      assert(step.text.includes('command python3 -B test_long.py; folder .'));
      assert(!step.text.includes('Result returned'));
      assert(!step.text.includes('VALIDATED_BATCH_'));
      assert(!step.text.includes('FIXTURE_ACCEPTANCE_OK'));
      if (step.data.workflow_terminal) { final = step; break; }
      observedRunning++;
      assert(step.text.includes('non-consuming preview'));
      assert(step.text.includes('elapsed '));
      produced.push(step.data.process.stdout_total_bytes);
      elapsed.push(Number(step.text.match(/elapsed ([0-9.]+)s/)[1]));
    }
    assert(final, 'long command must finish within bounded test window');
    assert(observedRunning >= 4, 'multiple live steps, not one completed command');
    assert(produced.every((n, i) => i === 0 || n > produced[i - 1]), 'actual output grows between snapshots');
    assert(elapsed.every((n, i) => i === 0 || n > elapsed[i - 1]), 'elapsed grows between snapshots');
    assert.equal(final.data.exit_code, 0);
    assert.equal(final.data.process.session_retained, false);
    assert.equal(final.data.process.stdout.match(/VALIDATED_BATCH_/g).length, 12);
    assert(final.data.process.stdout.includes('FIXTURE_ACCEPTANCE_OK'));
    assert(final.text.includes('acceptance still requires test/diff review'));
    const completed = await tool('process_status', {task_id: job});
    assert(completed.text.includes('command python3 -B test_long.py; folder .'));
    assert(completed.text.includes('duration '));
    job = null;
    const work = await tool('work_task', {action: 'list'});
    assert(work.data.work_items.some(w => w.work_id === workflow && w.phase === 'completed'));
    const inline = await tool('command_run', {workspace_id: workspaceID, executable: 'sh', cwd: '.',
      arguments: ['-c', "printf PRIVATE_SCRIPT_CANARY"], timeout_milliseconds: 5000});
    assert.equal(inline.data.stdout, 'PRIVATE_SCRIPT_CANARY');
    assert(inline.text.includes('[script and remaining arguments omitted]'));
    await tool('transaction_restore', {transaction_id: transaction,
      transaction_control_token: transactionToken});
    transaction = null; transactionToken = null;
    assert.equal(fs.readFileSync(path.join(workspace, 'sum.py'), 'utf8'), original);
    assert.equal((await tool('process_list')).data.processes.length, 0);
    assert.equal((await tool('transaction_list')).data.retained_transaction_count, 0);
    const result = {status: 'PASS', scope: 'isolated exact-binary MCP receipt test; NOT normal Chat rendering',
      binary_sha256: expectedHash, catalog_sha256: catalog.catalogEpoch, tool_count: 72,
      elapsed_milliseconds: Date.now() - started, live_snapshots: observedRunning,
      produced_stdout_bytes: produced, observed_elapsed_seconds: elapsed,
      fixture_checks: 120000, file_restored: true, jobs_remaining: 0, undo_remaining: 0, receipts};
    if (evidenceFile) fs.writeFileSync(evidenceFile, JSON.stringify(result, null, 2) + '\n', {mode: 0o600});
    console.log(JSON.stringify(result));
  } finally {
    if (!exited && job) await tool('process_cancel', {task_id: job,
      process_control_token: jobToken}).catch(() => {});
    if (!exited && transaction) await tool('transaction_restore', {transaction_id: transaction,
      transaction_control_token: transactionToken}).catch(() => {});
    child.stdin.end();
    const timer = setTimeout(() => child.kill('SIGTERM'), 3000);
    await exit; clearTimeout(timer);
    // Preserve the disposable fixture alongside the evidence; no user directories removed.
    console.log('FIXTURE_RETAINED ' + root);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
