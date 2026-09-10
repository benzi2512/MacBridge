// Compare exact binaries; this measures isolated stdio, not ChatGPT callability.
'use strict';
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const crypto = require('node:crypto'), readline = require('node:readline');
const {spawn, spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const argv = process.argv.slice(2);
if (argv.length !== 2 || argv[0] !== '--binary' || !path.isAbsolute(argv[1])) {
  console.error('usage: node command_run_responsiveness.cjs --binary /absolute/macbridge-mcp');
  process.exit(64);
}
const binary = fs.realpathSync(argv[1]), token = crypto.randomUUID();
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mb-command-response-')));
const workspace = path.join(root, 'workspace'), config = path.join(root, 'workspaces.json');
fs.chmodSync(root, 0o700); fs.mkdirSync(workspace, {mode: 0o700});
fs.writeFileSync(path.join(root, 'fixture-owner'), token, {mode: 0o600});
fs.writeFileSync(config, JSON.stringify({version: 1, workspaces: [
  {id: token, name: 'command-response-fixture', path: workspace},
]}), {mode: 0o600});
const result = {binary_sha256: crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),
  surface: 'isolated_web_tunnel_stdio', response_order: [], energy_measured: false,
  core_resource_usage: null}; // Node's child process API does not expose per-child rusage here.
const child = spawn(binary, ['--config', config, '--surface', 'web-tunnel'], {
  env: {PATH: '/usr/bin:/bin', HOME: root, TMPDIR: root}, stdio: ['pipe', 'pipe', 'pipe'],
});
let nextID = 0, exited = false, stderr = '', processSampled = false;
const pending = new Map(), observedDescendants = new Set();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const started = performance.now();
function failPending(error) {
  for (const item of pending.values()) { clearTimeout(item.timer); item.reject(error); }
  pending.clear();
}
const exit = new Promise(resolve => {
  child.once('error', error => { failPending(error); exited = true; resolve({spawn_error: error.message}); });
  child.once('exit', (code, signal) => { exited = true; failPending(new Error('isolated core exited'));
    resolve({code, signal}); });
});
child.stdin.on('error', failPending);
child.stderr.on('data', data => { stderr = (stderr + data).slice(-2048); });
readline.createInterface({input: child.stdout}).on('line', line => {
  try {
    const frame = JSON.parse(line), item = pending.get(frame.id);
    if (!item) return;
    pending.delete(frame.id); clearTimeout(item.timer);
    result.response_order.push({label: item.label, elapsed_ms: performance.now() - started});
    if (frame.error) item.reject(new Error(JSON.stringify(frame.error)));
    else item.resolve({payload: frame.result, elapsed_ms: performance.now() - item.started});
  } catch (error) { failPending(error); }
});
function request(label, method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++nextID, timer = setTimeout(() => {
      pending.delete(id); reject(new Error('request deadline: ' + label));
    }, 10000);
    pending.set(id, {label, resolve, reject, timer, started: performance.now()});
    child.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
  });
}
const call = (label, name, args = {}) => request(label, 'tools/call', {name, arguments: args});
const command = executable => ({workspace_id: token, executable, arguments: [],
  timeout_milliseconds: 1500, maximum_output_bytes: 4096});
function content(reply) {
  assert.equal(reply.payload.isError, false, JSON.stringify(reply.payload));
  return reply.payload.structuredContent;
}
function processTree() {
  const sampled = spawnSync('/bin/ps', ['-axo', 'pid=,ppid='], {encoding: 'utf8', timeout: 2000});
  if (sampled.status !== 0) throw new Error('could not verify process cleanup');
  return sampled.stdout.trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
}
function sampleDescendants() {
  const rows = processTree(), family = new Set([child.pid]);
  for (let changed = true; changed;) {
    changed = false;
    for (const [pid, ppid] of rows) if (family.has(ppid) && !family.has(pid)) {
      family.add(pid); observedDescendants.add(pid); changed = true;
    }
  }
  processSampled = true;
}
(async () => {
  try {
    // Separate binary cold-start/signature checks from request-loop latency.
    result.cold_start_ready_ms = (await request('ready', 'ping')).elapsed_ms;
    const first = call('blocked_command', 'command_run', command('cat'));
    const ping = request('ping', 'ping');
    const capability = call('capabilities', 'bridge_capabilities');
    const combined = Promise.all([first, ping, capability]);
    combined.catch(() => {}); // Attach before the independent process sample.
    await pause(100); sampleDescendants();
    const [run, pong, caps] = await combined, snapshot = content(run);
    result.ping_elapsed_ms = pong.elapsed_ms;
    result.ping_before_command = result.response_order.findIndex(x => x.label === 'ping')
      < result.response_order.findIndex(x => x.label === 'blocked_command');
    result.original_command = {running: snapshot.running, timed_out: snapshot.timed_out,
      cancelled: snapshot.cancelled, exit_code: snapshot.exit_code, stdout: snapshot.stdout,
      stderr: snapshot.stderr, elapsed_ms: run.elapsed_ms};
    assert.equal(snapshot.running, false); assert.equal(snapshot.timed_out, true);
    result.catalog_count = content(caps).catalog_count;
    result.after_timeout_exit_code = content(await call('after_timeout', 'command_run', command('true'))).exit_code;
    const invalid = await call('invalid_start', 'command_run', command('not-a-supported-command'));
    result.invalid_start_rejected = invalid.payload.isError === true;
    assert.equal(result.invalid_start_rejected, true);
    result.after_invalid_exit_code = content(await call('after_invalid', 'command_run', command('true'))).exit_code;
    assert.equal(result.after_timeout_exit_code, 0); assert.equal(result.after_invalid_exit_code, 0);
    result.tracked_processes_after = content(await call('final_process_list', 'process_list')).processes.length;
    assert.equal(result.tracked_processes_after, 0);
  } catch (error) { result.error = error.message; process.exitCode = 1; }
  finally {
    child.stdin.end();
    const stop = setTimeout(() => child.kill('SIGTERM'), 6000);
    result.core_exit = await exit; clearTimeout(stop);
    for (const item of pending.values()) clearTimeout(item.timer);
    try {
      if (!processSampled) sampleDescendants();
      const runtime = path.join(workspace, '.macbridge', 'runtime');
      for (let n = 0; n < 15 && fs.existsSync(runtime) && fs.readdirSync(runtime).length; n++) await pause(100);
      const alive = new Set(processTree().map(([pid]) => pid));
      result.observed_descendant_count = observedDescendants.size;
      result.observed_descendants_alive = [...observedDescendants].filter(pid => alive.has(pid));
      result.runtime_entries_after = fs.existsSync(runtime) ? fs.readdirSync(runtime) : [];
      assert(exited && !alive.has(child.pid));
      assert.equal(result.core_exit.code, 0);
      assert.equal(result.observed_descendants_alive.length, 0);
      assert.equal(result.runtime_entries_after.length, 0);
      assert.equal(fs.readFileSync(path.join(root, 'fixture-owner'), 'utf8'), token);
      assert.equal(fs.realpathSync(root), root);
      fs.rmSync(root, {recursive: true});
      result.fixture_removed = !fs.existsSync(root);
    } catch (error) { result.cleanup_error = error.message; result.retained_fixture = root; process.exitCode = 1; }
    if (stderr) result.core_stderr = stderr;
    console.log(JSON.stringify(result, null, 2));
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
