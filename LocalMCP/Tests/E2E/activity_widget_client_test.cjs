// Local bridge simulation, NOT normal-Chat acceptance. No packages or network.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/MacBridgeLocalCore/ActivityWidget.swift'), 'utf8');
const html = source.match(/static let html = #"""([\s\S]*?)"""#/)[1];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

class Element {
  constructor(tag='div'){this.tag=tag;this.children=[];this.dataset={};this.handlers={};this.style={};this.value='';this.checked=true;this.textContent='';this.hidden=false;}
  append(...nodes){this.children.push(...nodes);}
  replaceChildren(...nodes){this.children=nodes;}
  get firstChild(){return this.children[0];}
  get options(){return this.children;}
  addEventListener(type,handler){(this.handlers[type]??=[]).push(handler);}
  emit(type,event={}){for(const handler of this.handlers[type]??[])handler(event);}
  querySelectorAll(selector){assert.equal(selector,'details[open]');return this.children.filter(c=>c.tag==='details'&&c.open);}
}
const snapshot=(overrides={})=>({schema_version:1,scope:'shared_runtime_not_chat_scoped',instance_id:'owner-A',build_id:'test-build',catalog_count:52,
  jobs_known:true,jobs_truncated:false,jobs:[],history:[],transaction_count:1,busy:false,snapshot_stale:false,snapshot_ms:100,observed_ms:100,...overrides});
const settle=async()=>{for(let i=0;i<6;i++)await Promise.resolve();};
function fixture(initial=snapshot()){
  const nodes=new Map(Array.from(html.matchAll(/id="([^"]+)"/g),match=>[match[1],new Element()]));
  const window=new Element(),document=new Element();document.hidden=false;document.getElementById=id=>{assert(nodes.has(id),id);return nodes.get(id);};
  document.createElement=tag=>new Element(tag);document.documentElement={style:{}};window.parent={};
  let sequence=0,resolveCall;const timers=new Map(),calls=[];
  window.openai={toolOutput:initial,callTool:(name,args)=>{calls.push({name,args});return new Promise(resolve=>{resolveCall=resolve;});}};
  vm.runInNewContext(script,{window,document,console,setTimeout:(fn,ms)=>{timers.set(++sequence,{fn,ms});return sequence;},clearTimeout:id=>timers.delete(id)});
  return {nodes,window,document,timers,calls,resolve:async(result)=>{resolveCall(result);await settle();},
    fire(ms){const entry=[...timers].find(([,timer])=>timer.ms===ms);assert(entry,`timer ${ms} exists`);timers.delete(entry[0]);entry[1].fn();},
    get(id){return nodes.get(id);}};
}

(async()=>{
  assert(html.includes('<img class="mark"'));assert(html.includes('data:image/png;base64,'));
  assert(!html.includes('fetch('));assert(!html.includes('innerHTML'));assert(!html.includes('WebSocket('));
  const f=fixture();
  assert(f.get('mb-stats').textContent.includes('52'));
  assert([...f.timers.values()].some(t=>t.ms===10000));
  f.fire(10000);assert.equal(f.calls.length,1);assert.equal(f.calls[0].name,'bridge_activity');
  assert.equal(f.calls[0].args.instance_id,'owner-A');
  f.get('mb-refresh').emit('click');assert.equal(f.calls.length,1,'no overlapping read');
  await f.resolve({structuredContent:snapshot({observed_ms:200,jobs:[{task_id:'job-A',running:true}],history:[{id:'event-A',tool:'command_start',state:'returned',result:{task_id:'job-A'}}]})});
  assert([...f.timers.values()].some(t=>t.ms===3000));
  assert.equal(f.get('mb-history').children.length,1);
  f.document.hidden=true;f.document.emit('visibilitychange');assert.equal(f.timers.size,0);
  f.document.hidden=false;f.document.emit('visibilitychange');assert.equal(f.timers.size,1);
  f.get('mb-auto').checked=false;f.get('mb-auto').emit('change');assert.equal(f.timers.size,0);
  console.log('PASS: initial snapshot, owner-bound refresh, serial reads, adaptive intervals, hidden/pause');

  const timeout=fixture();timeout.fire(10000);timeout.fire(20000);
  assert(timeout.get('mb-status').textContent.includes('20'));
  timeout.get('mb-refresh').emit('click');assert.equal(timeout.calls.length,1);
  await timeout.resolve({structuredContent:snapshot({observed_ms:200})});
  assert.equal(timeout.timers.size,0,'late response cannot resume polling');
  console.log('PASS: timeout pauses without duplicate read or false success');

  const denied=fixture();denied.fire(10000);await denied.resolve({isError:true,structuredContent:{error:'host denied'}});
  assert.equal(denied.timers.size,0);assert.equal(denied.get('mb-status').dataset.error,'true');
  const changed=fixture();changed.fire(10000);await changed.resolve({structuredContent:snapshot({instance_id:'owner-B',observed_ms:200})});
  assert.equal(changed.timers.size,0);assert(changed.get('mb-refresh').disabled);
  changed.get('mb-refresh').emit('click');assert.equal(changed.calls.length,1);
  const disposed=fixture();disposed.window.emit('pagehide');assert.equal(disposed.timers.size,0);
  console.log('PASS: host error, owner change and disposal stop polling');

  const unsupported=fixture(null);delete unsupported.window.openai.callTool;
  unsupported.get('mb-refresh').emit('click');assert.equal(unsupported.calls.length,0);
  assert.equal(unsupported.timers.size,0);
  console.log('PASS: absent host bridge never invents live data');
})().catch(error=>{console.error(error);process.exitCode=1;});
