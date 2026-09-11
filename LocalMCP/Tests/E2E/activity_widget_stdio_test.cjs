// Real candidate stdio + background process; not a ChatGPT-host rendering test.
const fs=require('node:fs'),path=require('node:path');
const {spawn}=require('node:child_process');
const assert=require('node:assert/strict');
const readline=require('node:readline');
// An explicit path lets release verification use the exact artifact to promote.
const binary=process.argv[2]?path.resolve(process.argv[2]):path.resolve(__dirname,'../../.build/debug/macbridge-mcp');
const root=fs.mkdtempSync('/private/tmp/mb-card-e2e-');
const workspace=path.join(root,'workspace'),observer=path.join(root,'observer');
fs.mkdirSync(workspace,{mode:0o700});fs.mkdirSync(observer,{mode:0o700});
const config=path.join(root,'workspaces.json'),workspaceID='11111111-2222-4333-8444-555555555555';
// Foundation standardizes an existing /private/tmp path to /tmp. The registry
// resolves it back to the same owned directory; this does not widen access.
const configuredWorkspace=workspace.replace(/^\/private\/tmp\//,'/tmp/');
fs.writeFileSync(config,JSON.stringify({version:1,workspaces:[{id:workspaceID,name:'activity-fixture',path:configuredWorkspace}]}),{mode:0o600});
const child=spawn(binary,['--config',config,'--surface','web-tunnel','--observer-directory',observer],{env:{PATH:'/usr/bin:/bin',TMPDIR:root},stdio:['pipe','pipe','pipe']});
let sequence=0,errorText='',taskID,exited=false;const pending=new Map(),notifications=[];
const exit=new Promise(resolve=>child.on('exit',code=>{exited=true;for(const item of pending.values()){clearTimeout(item.timer);item.reject(new Error(`candidate exited ${code}: ${errorText}`));}pending.clear();resolve(code);}));
child.stderr.on('data',chunk=>{errorText=(errorText+chunk).slice(-4096);});
readline.createInterface({input:child.stdout}).on('line',line=>{
  try{const value=JSON.parse(line);if(value.method&&value.id===undefined){notifications.push(value.method);return;}const item=pending.get(value.id);if(!item)return;pending.delete(value.id);clearTimeout(item.timer);value.error?item.reject(new Error(JSON.stringify(value.error))):item.resolve(value.result);}catch(error){for(const item of pending.values())item.reject(error);}
});
function request(method,params={}){return new Promise((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`timeout: ${method}; ${errorText}`));},15000);pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
async function tool(name,args={}){const value=await request('tools/call',{name,arguments:args});assert.equal(value.isError,false,JSON.stringify(value));return value.structuredContent;}
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
(async()=>{
  try{
    const discovered=await request('server/discover');
    const initialized=await request('initialize',{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'activity-fixture',version:'1'}});
    assert.deepEqual(discovered.capabilities,initialized.capabilities);
    assert.deepEqual(discovered.capabilities.resources,{listChanged:false});
    assert.deepEqual(discovered.capabilities.tools,{listChanged:false});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
    const listed=await request('resources/list');assert.equal(listed.resources.length,3);
    assert(!notifications.includes('notifications/tools/list_changed'),'stable catalog emitted an unsolicited refresh');
    const expected=new Map([
      ['ui://macbridge/activity-chatgpt-v3.html','text/html+skybridge'],
      ['ui://macbridge/activity-chatgpt-v2.html','text/html+skybridge'],
      ['ui://macbridge/activity-v1.html','text/html;profile=mcp-app']
    ]);
    assert.deepEqual(new Set(listed.resources.map(r=>r.uri)),new Set(expected.keys()));
    const tools=await request('tools/list');assert.equal(tools.tools.length,72);
    assert(tools.tools.some(t=>t.name==='work_task'));
    const render=tools.tools.find(t=>t.name==='bridge_activity_view');
    assert.equal(render._meta.ui.resourceUri,'ui://macbridge/activity-chatgpt-v3.html');
    assert.equal(render._meta['openai/outputTemplate'],render._meta.ui.resourceUri);
    let firstHTML;
    for(const descriptor of listed.resources){
      const resource=await request('resources/read',{uri:descriptor.uri});
      assert.equal(resource.contents.length,1);
      const content=resource.contents[0];
      assert.equal(content.uri,descriptor.uri);
      assert.equal(content.mimeType,descriptor.mimeType);assert.equal(content.mimeType,expected.get(content.uri));
      assert(content.text.includes('mb-activity'));
      assert(content.text.includes('<img class="mark"'));
      assert(content.text.includes('data:image/png;base64,'));
      assert.deepEqual(content._meta.ui.csp,{connectDomains:[],resourceDomains:[]});
      if(firstHTML!==undefined)assert.equal(content.text,firstHTML);else firstHTML=content.text;
    }
    const view=await tool('bridge_activity_view'),owner=view.instance_id;
    assert.equal(view.catalog_count,72);assert.equal(view.snapshot_stale,false);
    assert.deepEqual(view.ui_resource_delivery,{read_count:3,last_outcome:'response_prepared'});
    const start=await tool('command_start',{workspace_id:workspaceID,executable:'sh',arguments:['-c',"printf 'step-1\\n'; sleep 0.4; printf 'step-2\\n'; sleep 0.4; printf 'done\\n'"],maximum_output_bytes:8192});
    taskID=start.task_id;let sawRunning=false,sawDone=false,sawPartial=false;
    for(let i=0;i<60;i++){
      const data=await tool('bridge_activity',{instance_id:owner,task_id:taskID});
      assert.equal(data.instance_id,owner);assert.equal(data.log.output_consumed,false);assert.equal(data.log.session_retained,true);
      sawRunning ||= data.log.running===true;
      sawPartial ||= data.log.running===true && data.log.stdout.includes('step-1') && !data.log.stdout.includes('done');
      if(data.log.running===false){assert.equal(data.log.exit_code,0);assert(data.log.stdout.includes('done'));sawDone=true;break;}
      await pause(40);
    }
    assert(sawRunning && sawPartial && sawDone,'running -> partial log -> completed');
    const drain=await tool('process_output',{task_id:taskID});assert.equal(drain.session_retained,false);taskID=null;
    assert.equal((await tool('process_list')).processes.length,0);
    console.log('PASS: discovery/initialize agreement, all template MIME/URI contracts over real stdio, identical HTML, 72 tools, background progress, partial/final log, preserved handle and final drain. Host rendering not tested.');
  }finally{
    if(taskID && !exited)await tool('process_cancel',{task_id:taskID}).catch(()=>{});
    child.stdin.end();
    const shutdown=setTimeout(()=>child.kill('SIGTERM'),3000);await exit;clearTimeout(shutdown);
    for(const item of pending.values())clearTimeout(item.timer);
    fs.rmSync(root,{recursive:true,force:true});
    assert(!fs.existsSync(root));
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
