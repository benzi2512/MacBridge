'use strict';
// Exact local artifact, disposable owner, no downloads or live credentials.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawn}=require('node:child_process'),rl=require('node:readline');
const assert=require('node:assert/strict');
const net=require('node:net');
const binary=path.resolve(process.argv[2]);
const hold=process.argv.includes('--hold');
const root=fs.mkdtempSync('/private/tmp/mb-work-e2e-');
const workspace=path.join(root,'workspace'),observer=path.join(root,'observer');
fs.mkdirSync(workspace,{mode:0o700});fs.mkdirSync(observer,{mode:0o700});
const workspaceID='11111111-2222-4333-8444-555555555555';
const config=path.join(root,'workspaces.json');
fs.writeFileSync(config,JSON.stringify({version:1,workspaces:[{id:workspaceID,name:'Work activity fixture',path:workspace.replace(/^\/private\/tmp\//,'/tmp/') }]}),{mode:0o600});
const baseline='def add(a, b):\n    return a - b\n';
fs.writeFileSync(path.join(workspace,'sum.py'),baseline);
fs.writeFileSync(path.join(workspace,'test_sum.py'),'from sum import add\nassert add(2, 3) == 5\nprint("WORK_TEST_PASS")\n');
const child=spawn(binary,['--config',config,'--surface','web-tunnel','--observer-directory',observer],{env:{PATH:'/usr/bin:/bin',TMPDIR:root},stdio:['pipe','pipe','pipe']});
let sequence=0,stderr='',exited=false,checks=0;const pending=new Map();
const exit=new Promise(resolve=>child.once('exit',code=>{exited=true;for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error('owner exited '+code));}pending.clear();resolve(code);}));
child.stderr.on('data',d=>{stderr=(stderr+d).slice(-4096);});
rl.createInterface({input:child.stdout}).on('line',line=>{try{const r=JSON.parse(line),p=pending.get(r.id);if(!p)return;pending.delete(r.id);clearTimeout(p.timer);r.error?p.reject(new Error(JSON.stringify(r.error))):p.resolve(r.result);}catch(e){for(const p of pending.values())p.reject(e);}});
function rpc(method,params={}){return new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(new Error('timeout '+method+' '+stderr));},20000);pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
async function call(name,args={},error=false){const result=await rpc('tools/call',{name,arguments:args});assert.equal(result.isError,error,JSON.stringify(result));checks++;return result;}
async function tool(name,args={}){return (await call(name,args)).structuredContent;}
const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
function observe(request){return new Promise((resolve,reject)=>{
  const client=net.createConnection(path.join(observer,'observer.sock'));let data='';
  client.setTimeout(5000,()=>client.destroy(new Error('observer timeout')));
  client.on('connect',()=>client.write(JSON.stringify(request)+'\n'));
  client.on('data',chunk=>{data+=chunk;if(data.length>1048576)client.destroy(new Error('observer reply exceeded limit'));else if(data.includes('\n')){client.end();try{const reply=JSON.parse(data.split('\n')[0]);resolve(reply.ok===true?reply.result:reply);}catch(e){reject(e);}}});
  client.on('error',reject);
});}
let a,b,aControl,bControl,taskID,processControl,tx,txControl;
(async()=>{try{
  const catalog=await rpc('tools/list');assert.equal(catalog.tools.length,77);
  for(const name of ['file_patch','command_start','command_run','file_search'])assert(catalog.tools.find(t=>t.name===name).inputSchema.properties.work_id);
  const owner=(await tool('bridge_capabilities')).instance_id;
  const startedA=await tool('work_task',{action:'begin',title:'Fix addition and run tests',chat_label:'Chat A (fixture)',workspace_id:workspaceID});
  const startedB=await tool('work_task',{action:'begin',title:'Review another task',chat_label:'Chat B (fixture)',workspace_id:workspaceID});
  a=startedA.work_id;aControl=startedA.work_control_token;
  b=startedB.work_id;bControl=startedB.work_control_token;
  assert(a&&b&&a!==b);
  assert(aControl&&bControl);
  await tool('work_task',{action:'update',work_id:b,work_control_token:bControl,workspace_id:workspaceID,status:'waiting_user'});
  await tool('file_read',{work_id:a,work_control_token:aControl,workspace_id:workspaceID,path:'sum.py'});
  const initial=await observe({action:'snapshot',instance_id:owner});
  assert.equal(initial.observer_file_preview,true);
  const selectedEvent=initial.history.find(r=>r.tool==='file_read'&&r.work_id===a).id;
  const previewRequest={action:'file_preview',instance_id:owner,event_id:selectedEvent};
  const before=await observe(previewRequest);assert.equal(before.text,baseline);assert.equal(before.truncated,false);
  const unchanged=await observe({...previewRequest,known_version:before.version});
  assert.equal(unchanged.unchanged,true);assert.equal(unchanged.text,undefined);
  const wrongOwner=await observe({...previewRequest,instance_id:crypto.randomUUID()});assert(wrongOwner.error);
  const suppliedPath=await observe({...previewRequest,path:'/etc/passwd'});assert(suppliedPath.error);
  const run=()=>tool('command_run',{work_id:a,work_control_token:aControl,workspace_id:workspaceID,executable:'python3',arguments:['-B','test_sum.py'],timeout_milliseconds:10000,maximum_output_bytes:8192});
  assert.notEqual((await run()).exit_code,0,'real baseline must fail');
  const patch=await call('file_patch',{work_id:a,work_control_token:aControl,workspace_id:workspaceID,path:'sum.py',expected_sha256:hash(baseline),old_text:'return a - b',new_text:'return a + b'});
  tx=patch.structuredContent.transaction_id;txControl=patch.structuredContent.transaction_control_token;assert.equal(patch.structuredContent.work_id,a);
  const after=await observe({...previewRequest,known_version:before.version});
  assert.equal(after.text,baseline.replace('a - b','a + b'));assert.notEqual(after.version,before.version);
  assert(patch.content.some(x=>x.text?.includes('sum.py')),'summary names actual file');
  const passed=await run();assert.equal(passed.exit_code,0);assert(passed.stdout.includes('WORK_TEST_PASS'));
  const startedJob=await tool('command_start',{work_id:a,work_control_token:aControl,workspace_id:workspaceID,executable:'cat',arguments:[],maximum_output_bytes:8192});
  taskID=startedJob.task_id;processControl=startedJob.process_control_token;
  await call('work_task',{action:'finish',work_id:a,work_control_token:aControl,workspace_id:workspaceID,status:'completed'},true);
  const active=await tool('bridge_activity',{instance_id:owner});
  assert.equal(active.work_items.find(w=>w.work_id===a).phase,'executing');
  assert.equal(active.work_items.find(w=>w.work_id===b).phase,'waiting_user');
  const rows=active.history.filter(r=>r.work_id===a);assert(rows.some(r=>r.detail?.command_preview?.includes('python3')));
  const observedPatch=rows.find(r=>r.tool==='file_patch');
  assert.equal(observedPatch.result.mutation_performed,true);assert.equal(observedPatch.result.replacements,1);
  assert.equal(observedPatch.detail.edit_count,1);
  assert(!active.history.some(r=>r.work_id===b&&r.tool==='command_run'));
  if(hold){
    console.log('WORK_UI_HOLD '+JSON.stringify({observer,owner,work_a:a,work_b:b,task_id:taskID,root,binary_sha256:hash(fs.readFileSync(binary))}));
    const input=rl.createInterface({input:process.stdin});
    let expired=false;
    const holdDeadline=setTimeout(()=>{expired=true;input.close();},600000);
    try{for await(const line of input){
        if(line.trim()==='finish-job'){await tool('process_input',{task_id:taskID,process_control_token:processControl,content:'UI_HANDLE_SURVIVED\n',close_stdin:true});console.log('JOB_RELEASED');}
        if(line.trim()==='finish'){input.close();break;}
    }}finally{clearTimeout(holdDeadline);input.close();}
    assert(!expired,'UI hold exceeded its 10-minute fixture lifetime');
  }else await tool('process_input',{task_id:taskID,process_control_token:processControl,content:'WORK_HANDLE_SURVIVED\n',close_stdin:true});
  // Bound the wait with the real process wait API; output is consumed only here.
  for(let i=0;i<5;i++){if(!(await tool('process_wait',{task_id:taskID,process_control_token:processControl,maximum_wait_milliseconds:1000})).running)break;}
  const drained=await tool('process_output',{task_id:taskID,process_control_token:processControl});assert.equal(drained.exit_code,0);assert.equal(drained.session_retained,false);taskID=null;processControl=null;
  const waiting=await tool('bridge_activity',{instance_id:owner});assert.equal(waiting.work_items.find(w=>w.work_id===a).phase,'waiting_next_step');
  await tool('transaction_restore',{work_id:a,work_control_token:aControl,transaction_id:tx,transaction_control_token:txControl});tx=null;txControl=null;
  const restored=await observe({...previewRequest,known_version:after.version});assert.equal(restored.text,baseline);
  assert.equal(fs.readFileSync(path.join(workspace,'sum.py'),'utf8'),baseline);
  // History rollover does not erase a task or accidentally merge same-workspace chats.
  for(let i=0;i<66;i++)await tool('directory_list',{work_id:a,work_control_token:aControl,workspace_id:workspaceID,path:'.'});
  const rollover=await tool('bridge_activity',{instance_id:owner});assert.equal(rollover.work_items.length,2);assert.equal(rollover.work_items.find(w=>w.work_id===b).phase,'waiting_user');
  await tool('work_task',{action:'finish',work_id:a,work_control_token:aControl,workspace_id:workspaceID,status:'completed'});
  await tool('work_task',{action:'finish',work_id:b,work_control_token:bControl,workspace_id:workspaceID,status:'completed'});
  const finished=await tool('work_task',{action:'list',workspace_id:workspaceID});assert(finished.work_items.every(w=>w.phase==='completed'));
  const gateway=await tool('developer_task',{action:'execute_task',workspace_id:workspaceID,cwd:'.',title:'Developer gateway E2E',chat_label:'Synthetic E2E',executable:'sh',arguments:['-c',"printf 'DEVELOPER_GATEWAY_OK\\n'"],maximum_output_bytes:4096});
  assert(gateway.workflow_id&&gateway.task_id&&gateway.next_action==='continue_task');
  let terminal;const gatewayWorkControl=gateway.work_control_token,gatewayProcessControl=gateway.process_control_token;
  for(let i=0;i<20;i++){
    terminal=await tool('developer_task',{action:'continue_task',workflow_id:gateway.workflow_id,work_control_token:gatewayWorkControl,process_control_token:gatewayProcessControl});
    if(terminal.workflow_terminal)break;
    await new Promise(resolve=>setTimeout(resolve,25));
  }
  assert.equal(terminal.workflow_terminal,true);assert.equal(terminal.exit_code,0);
  assert.equal(terminal.process.stdout,'DEVELOPER_GATEWAY_OK\n');
  const afterGateway=await tool('work_task',{action:'list',workspace_id:workspaceID});
  assert.equal(afterGateway.work_items.find(w=>w.work_id===gateway.workflow_id).phase,'completed');
  await call('command_start',{work_id:a,workspace_id:workspaceID,executable:'cat',arguments:[]},true);
  assert.equal((await tool('process_list')).processes.length,0);
  assert.equal((await tool('transaction_list')).retained_transaction_count,0);
  console.log(JSON.stringify({status:'PASS',checks,scope:'exact-binary local stdio + selected-file observer IPC, not normal Chat or inline rendering',preview_changed_and_restored:true,preview_unchanged_omits_text:true,file_restored:true,processes:0,undo:0}));
}finally{
  if(taskID&&!exited)await tool('process_cancel',{task_id:taskID,process_control_token:processControl}).catch(()=>{});
  if(tx&&!exited)await tool('transaction_restore',{transaction_id:tx,transaction_control_token:txControl}).catch(()=>{});
  child.stdin.end();const deadline=setTimeout(()=>child.kill('SIGTERM'),3000);await exit;clearTimeout(deadline);
  fs.rmSync(root,{recursive:true,force:true});assert(!fs.existsSync(root));
}})().catch(e=>{console.error(e);process.exitCode=1;});
