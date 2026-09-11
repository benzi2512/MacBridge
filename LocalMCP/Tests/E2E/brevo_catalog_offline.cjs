// Exact-binary, real JSON-RPC acceptance. No packages, credentials or network.
// Sandboxed child may write only outside the user's home; fixtures are disposable.
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const crypto = require('node:crypto'), {spawn} = require('node:child_process');
const assert = require('node:assert/strict');
const {RPCSession} = require('./rpc_session.cjs');
const [binary, expectedHash, output] = process.argv.slice(2);
assert(binary?.startsWith('/') && output?.startsWith('/'));
assert(/^[0-9a-f]{64}$/.test(expectedHash));
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'), expectedHash);
assert(!fs.existsSync(output), 'Do not overwrite evidence');
const fixture = fs.mkdtempSync('/private/tmp/mb-brevo-rpc-');
fs.chmodSync(fixture, 0o700);
const work = path.join(fixture, 'work'); fs.mkdirSync(work, {mode: 0o700});
const config = path.join(fixture, 'workspaces.json');
fs.writeFileSync(config, JSON.stringify({version: 1, workspaces: [{
  id: '11111111-2222-4333-8444-555555555555', name: 'Brevo RPC fixture', path: work, allow_broad_access: false
}]}), {mode: 0o600});
const protectedHome = os.homedir();
assert(path.isAbsolute(protectedHome), 'Private account home must be absolute');
// The exact hash-checked executable may itself reside in the owner's home.
// Permit that one file, never the containing checkout or other home content.
const profile = `(version 1)(allow default)(deny network*)(deny file-read* (subpath ${JSON.stringify(protectedHome)}))
(allow file-read-metadata)(allow file-read* (literal ${JSON.stringify(binary)}))(deny file-write*)
(allow file-write* (subpath ${JSON.stringify(fixture)}) (literal "/dev/null"))`;
const child = spawn('/usr/bin/sandbox-exec', ['-p', profile, binary, '--config', config, '--surface', 'web-tunnel'], {
  cwd: work, env: {PATH: '/usr/bin:/bin', TMPDIR: fixture, CFFIXED_USER_HOME: fixture}, stdio: ['pipe', 'pipe', 'pipe']
});
const session = new RPCSession(child), evidence = session.evidence;
const rpc = (method, params = {}) => session.request(method, params);
async function tool(name, args = {}) {
  const result = await rpc('tools/call', {name, arguments: args});
  assert.equal(result.isError, false, JSON.stringify(result));
  return result.structuredContent || JSON.parse(result.content.find(c => c.type === 'text').text);
}
const probes = [
  ['brevo_contacts', {action: 'create', email: 'fixture@example.invalid'}],
  ['brevo_contacts', {action: 'update', identifier: 'fixture@example.invalid', attributes: {FIRSTNAME: 'Fixture'}}],
  ['brevo_contacts', {action: 'import', contacts: [{email: 'fixture@example.invalid'}], list_ids: [1]}],
  ['brevo_lists', {action: 'create', name: 'Disposable fixture', folder_id: 1}],
  ['brevo_lists', {action: 'delete', list_id: 1}],
  ['brevo_lists', {action: 'add_members', list_id: 1, emails: ['fixture@example.invalid']}],
  ['brevo_templates', {action: 'create', name: 'Fixture', subject: 'Fixture', sender: {id: 1}, html_content: '<p>Fixture only</p>'}],
  ['brevo_templates', {action: 'activate', template_id: 1}],
  ['brevo_events', {action: 'track', event_name: 'fixture', identifiers: {email_id: 'fixture@example.invalid'}}],
  ['brevo_deliverability', {action: 'unblock_contact', email: 'fixture@example.invalid'}],
  ['brevo_webhooks', {action: 'create', type: 'transactional', events: ['delivered'], url: 'https://receiver.example.invalid/events'}],
  ['brevo_campaign', {action: 'update', campaign_id: 77, subject: 'Unsent dry-run fixture'}],
  ['brevo_campaign', {action: 'send_now', campaign_id: 77}],
  ['brevo_campaign', {action: 'schedule', campaign_id: 77, scheduled_at: '2099-01-01T12:00:00Z'}],
];
(async () => {
  let report;
  try {
    const init = await rpc('initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'brevo-offline-acceptance', version: '1'}});
    assert.equal(init.protocolVersion, '2025-06-18');
    session.notify('notifications/initialized');
    const catalog = (await rpc('tools/list')).tools;
    assert.equal(catalog.length, 72);
    const names = catalog.map(t => t.name), brevo = names.filter(n => n.startsWith('brevo_'));
    assert.equal(new Set(names).size, 72); assert.equal(brevo.length, 12);
    for (const name of brevo) {
      const spec = catalog.find(t => t.name === name);
      assert.equal(spec.inputSchema.additionalProperties, false);
      for (const forbidden of ['api_key', 'credential_path', 'transport', 'http_method']) assert(!spec.inputSchema.properties[forbidden]);
      const exact = await tool('tool_catalog', {names: [name], detail: 'schemas'});
      assert.deepEqual(exact.tools, [spec]);
    }
    for (const [name, args] of probes) {
      const dry = await tool(name, args);
      assert.equal(dry.dry_run, true); assert.equal(dry.write_occurred, false);
      assert.equal(dry.credential_read, false); assert.equal(dry.network_request, false);
    }
    for (const name of ['brevo_segments', 'brevo_automations', 'brevo_webhooks']) {
      const cap = await tool(name, {action: 'capabilities'});
      assert.equal(cap.status, 'documented_capability_limit'); assert.equal(cap.network_request, false);
    }
    // Live writes without a write gate and malformed inputs must stop before credential access.
    const rejected = await rpc('tools/call', {name: 'brevo_lists', arguments: {
      action: 'create', name: 'Must never exist', folder_id: 1, apply: true}});
    assert.equal(rejected.isError, true);
    assert(JSON.stringify(rejected).includes('confirm_write'));
    const identity = await tool('bridge_capabilities');
    assert.equal(identity.catalog_count, 72);
    assert.equal(identity.network_default, 'loopback_only');
    assert.equal(identity.mcp_executable_sha256, expectedHash);
    assert.equal(identity.desktop_open_enabled, false);
    assert.equal(identity.computer_grants_configured, 0);
    const workspaceID = '11111111-2222-4333-8444-555555555555';
    for (const [name, args] of [
      ['desktop_open', {workspace_id: workspaceID, action: 'folder', path: '.'}],
      ['computer_control', {workspace_id: workspaceID, bundle_id: 'com.apple.TextEdit', action: 'status'}],
      ['network_command', {workspace_id: workspaceID, grant_id: 'aaaaaaaa-1111-4222-8333-444444444444', executable: 'sh', arguments: ['-c', 'true']}],
    ]) {
      const result = await rpc('tools/call', {name, arguments: args});
      assert.equal(result.isError, true, 'New desktop capabilities must be default off');
    }
    assert(!JSON.stringify(evidence).includes('xkeysib-'));
    const ended = await session.stop();
    assert.equal(ended.code, 0, 'Exact core must exit cleanly after EOF');
    report = {status: 'PASS', identity, brevo_tools: brevo,
      dry_run_probes: probes.length, exact_schema_queries: brevo.length, rpc_calls: session.sequence,
      network_denied_by_os: true, production_home_contents_denied_by_os: true, production_runtime_touched: false,
      exact_executable_read_exception: true, filesystem_metadata_allowed: true, core_exit_code: ended.code,
      production_acceptance: false, normal_chat_acceptance: false, evidence};
  } finally {
    try { await session.stop(); }
    finally {
      assert(fixture.startsWith('/private/tmp/mb-brevo-rpc-'));
      fs.rmSync(fixture, {recursive: true, force: true}); // Only this test's newly created fixture.
    }
  }
  // Do not publish a PASS before clean child shutdown and fixture cleanup.
  assert(report);
  fs.writeFileSync(output, JSON.stringify(report, null, 2), {mode: 0o600, flag: 'wx'});
  console.log(JSON.stringify({status: 'PASS', binary_sha256: expectedHash, catalog_count: 72,
    catalog_sha256: report.identity.catalog_sha256, build_id: report.identity.build_id,
    dry_run_probes: probes.length, rpc_calls: session.sequence, output}));
})().catch(error => { console.error(JSON.stringify({status: 'FAIL', code: error.code || error.name,
  child_exit_code: child.exitCode, child_signal: child.signalCode,
  rpc_calls: session.sequence, stderr_bytes: session.stderrBytes})); process.exitCode = 1; });
