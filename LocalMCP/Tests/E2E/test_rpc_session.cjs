'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {EventEmitter}=require('node:events'),{PassThrough}=require('node:stream');
const {RPCSession}=require('./rpc_session.cjs');

class FakeChild extends EventEmitter {
  constructor({ignoreSignals=false}={}) {
    super();this.stdin=new PassThrough();this.stdout=new PassThrough();this.stderr=new PassThrough();
    this.signals=[];this.ignoreSignals=ignoreSignals;this.closed=false;
  }
  kill(signal) {this.signals.push(signal);if(!this.ignoreSignals)queueMicrotask(()=>this.close(null,signal));return true;}
  close(code=0,signal=null) {if(this.closed)return;this.closed=true;this.emit('close',code,signal);}
  reply(id,result={ok:true}) {this.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');}
}
const sessionFor=(options={},childOptions={})=>{
  const child=new FakeChild(childOptions),session=new RPCSession(child,{requestTimeoutMs:200,stopTimeoutMs:20,...options});
  return {child,session};
};
const fails=async(promise,code)=>assert.rejects(promise,error=>error.code===code&&error.message===code);

test('valid split and coalesced frames, notifications and clean EOF',async()=>{
  const {child,session}=sessionFor();child.stdin.once('finish',()=>child.close());
  const first=session.request('one'),second=session.request('two');
  child.stdout.write('{"jsonrpc":"2.0","id":1,"res');
  child.stdout.write('ult":{"ok":1}}\n{"jsonrpc":"2.0","method":"progress"}\n');
  child.reply(2,{ok:2});assert.deepEqual(await first,{ok:1});assert.deepEqual(await second,{ok:2});
  const stopping=session.stop();assert.strictEqual(session.stop(),stopping);
  assert.deepEqual(await stopping,{code:0,signal:null});assert.equal(session.evidence.length,3);
  assert.equal(session.pending.size,0);assert.equal(session.sequence,2);assert.equal(child.signals.length,0);
});

for(const code of [0,7])test('early child exit '+code+' rejects pending RPC and already-closed shutdown',async()=>{
  const {child,session}=sessionFor();const rejected=fails(session.request('initialize'),'unexpected_exit');
  child.close(code);await rejected;await fails(session.stop(),'unexpected_exit');assert.equal(session.pending.size,0);
});

test('exit before a first request is never success',async()=>{
  const {child,session}=sessionFor();child.close(0);
  await fails(session.request('initialize'),'unexpected_exit');await fails(session.stop(),'unexpected_exit');
});

test('nonzero exit after all replies and requested EOF invalidates the run',async()=>{
  const {child,session}=sessionFor();const result=session.request('last');child.reply(1);await result;
  const stopped=fails(session.stop(),'nonzero_exit');child.close(9);await stopped;
});

test('spawn error has a bounded closed outcome',async()=>{
  const {child,session}=sessionFor();const rejected=fails(session.request('initialize'),'spawn_failed');
  child.emit('error',new Error('do not echo child diagnostics'));await rejected;await fails(session.stop(),'spawn_failed');
});

for(const stream of ['stdin','stdout','stderr'])test(stream+' error rejects pending requests',async()=>{
  const {child,session}=sessionFor();const rejected=fails(session.request('initialize'),stream+'_failed');
  child[stream].emit('error',new Error('private diagnostic'));await rejected;await fails(session.stop(),stream+'_failed');
});

for(const [name,frame,code] of [
  ['invalid JSON','private diagnostic\n','invalid_json'],
  ['wrong envelope','{"id":1,"result":{}}\n','invalid_frame'],
  ['unknown reply','{"jsonrpc":"2.0","id":99,"result":{}}\n','unexpected_response'],
  ['two result types','{"jsonrpc":"2.0","id":1,"result":{},"error":{}}\n','unexpected_response'],
  ['RPC error','{"jsonrpc":"2.0","id":1,"error":{"message":"private diagnostic"}}\n','rpc_error'],
])test(name+' is fail-closed without raw diagnostic errors',async()=>{
  const {child,session}=sessionFor();const rejected=fails(session.request('initialize'),code);
  child.stdout.write(frame);await rejected;await fails(session.stop(),code);
  assert(!session.failure.message.includes('private diagnostic'));
});

test('no-newline output is bounded before frame allocation',async()=>{
  const {child,session}=sessionFor({maximumStdoutBytes:32});const rejected=fails(session.request('initialize'),'stdout_limit');
  child.stdout.write(Buffer.alloc(33,120));await rejected;assert.equal(session.buffer.length,0);await fails(session.stop(),'stdout_limit');
});

test('invalid UTF-8 cannot silently become a different result string',async()=>{
  const {child,session}=sessionFor();const rejected=fails(session.request('initialize'),'invalid_json');
  child.stdout.write(Buffer.concat([Buffer.from('{"jsonrpc":"2.0","id":1,"result":"'),Buffer.from([255]),Buffer.from('"}\n')]));
  await rejected;await fails(session.stop(),'invalid_json');
});

test('stderr flooding is bounded and content is not retained',async()=>{
  const {child,session}=sessionFor({maximumStderrBytes:16});const rejected=fails(session.request('initialize'),'stderr_limit');
  child.stderr.write('private diagnostic that must not be echoed');await rejected;await fails(session.stop(),'stderr_limit');
  assert.equal(session.evidence.length,0);assert.equal(typeof session.stderr,'undefined');
});

test('trailing incomplete frame after valid replies cannot pass',async()=>{
  const {child,session}=sessionFor();const reply=session.request('one');child.reply(1);await reply;
  child.stdout.write('{');const stopped=fails(session.stop(),'truncated_frame');child.close();await stopped;
});

test('duplicate response invalidates the entire completed exchange',async()=>{
  const {child,session}=sessionFor();const reply=session.request('one');child.reply(1);await reply;
  child.reply(1);await fails(session.stop(),'unexpected_response');
});

test('request timeout rejects rather than leaving an unresolved promise',async()=>{
  const {session}=sessionFor({requestTimeoutMs:10});await fails(session.request('silent'),'request_timeout');
  await fails(session.stop(),'request_timeout');assert.equal(session.pending.size,0);
});

test('shutdown that ignores signals has a bounded failed outcome',async()=>{
  const {child,session}=sessionFor({stopTimeoutMs:10},{ignoreSignals:true});
  await fails(session.stop(),'shutdown_timeout');assert.deepEqual(child.signals,['SIGTERM','SIGKILL']);
  assert(child.stdin.destroyed&&child.stdout.destroyed&&child.stderr.destroyed);
});

test('new requests are rejected once shutdown starts',async()=>{
  const {child,session}=sessionFor();const stopping=session.stop();
  await fails(session.request('late'),'session_closed');assert.throws(()=>session.notify('late'),{code:'session_closed'});
  child.close();await stopping;
});

test('EOF alone cannot pass while an RPC remains unresolved',async()=>{
  const {child,session}=sessionFor();const request=fails(session.request('unanswered'),'unexpected_exit');
  const stopping=fails(session.stop(),'unexpected_exit');child.close();await request;await stopping;
});
