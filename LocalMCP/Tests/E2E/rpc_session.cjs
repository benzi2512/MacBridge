'use strict';
// Test-only bounded stdio client. A passing receipt must follow stop(), not exit.
// No process launch, permissions, network or production runtime access here.
class RPCSession {
  constructor(child, {requestTimeoutMs=10000, stopTimeoutMs=2000,
    maximumStdoutBytes=2*1024*1024, maximumStderrBytes=65536}={}) {
    this.child=child; this.requestTimeoutMs=requestTimeoutMs; this.stopTimeoutMs=stopTimeoutMs;
    this.maximumStdoutBytes=maximumStdoutBytes; this.maximumStderrBytes=maximumStderrBytes;
    this.pending=new Map(); this.evidence=[]; this.sequence=0; this.stdoutBytes=0; this.stderrBytes=0;
    this.buffer=Buffer.alloc(0); this.failure=null; this.closing=false; this.closed=false;
    this.finished=new Promise(resolve=>{this.resolveFinished=resolve;});
    child.stdin.on('error',()=>this.fail('stdin_failed'));
    child.stdout.on('error',()=>this.fail('stdout_failed'));
    child.stdout.on('data',chunk=>this.receive(Buffer.from(chunk)));
    child.stderr.on('error',()=>this.fail('stderr_failed'));
    child.stderr.on('data',chunk=>{
      this.stderrBytes+=chunk.length;
      if(this.stderrBytes>this.maximumStderrBytes)this.fail('stderr_limit');
      // Do not retain or echo vendor diagnostics: they can contain secrets.
    });
    child.once('error',()=>this.fail('spawn_failed'));
    // Registered before the first request. close includes pipe drainage; a
    // late once('exit') listener can miss an already-exited child forever.
    child.once('close',(code,signal)=>{
      this.closed=true;
      if(this.buffer.length)this.fail('truncated_frame');
      if(this.pending.size||!this.closing)this.fail('unexpected_exit');
      if(code!==0||signal)this.fail('nonzero_exit');
      this.resolveFinished({code,signal});
    });
  }

  fail(code) {
    if(!this.failure){this.failure=Object.assign(new Error(code),{code});}
    for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(this.failure);}
    this.pending.clear();
    if(!this.closed)this.child.kill('SIGTERM');
  }

  receive(chunk) {
    if(this.failure)return;
    this.stdoutBytes+=chunk.length;
    if(this.stdoutBytes>this.maximumStdoutBytes){this.fail('stdout_limit');return;}
    this.buffer=Buffer.concat([this.buffer,chunk]);
    for(let end;(end=this.buffer.indexOf(10))>=0;){
      const line=this.buffer.subarray(0,end);this.buffer=this.buffer.subarray(end+1);
      if(!line.length)continue;
      let frame;
      try{frame=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(line));}catch{this.fail('invalid_json');return;}
      if(!frame||frame.jsonrpc!=='2.0'){this.fail('invalid_frame');return;}
      if(!Object.hasOwn(frame,'id')&&typeof frame.method==='string'){
        this.evidence.push({notification:frame});continue;
      }
      const waiter=this.pending.get(frame.id);
      if(!waiter||Object.hasOwn(frame,'result')===Object.hasOwn(frame,'error')){
        this.fail('unexpected_response');return;
      }
      this.evidence.push({request:waiter.request,response:frame});
      if(Object.hasOwn(frame,'error')){this.fail('rpc_error');return;}
      this.pending.delete(frame.id);clearTimeout(waiter.timer);waiter.resolve(frame.result);
    }
  }

  request(method,params={}) {
    if(this.failure)return Promise.reject(this.failure);
    if(this.closed||this.closing)return Promise.reject(Object.assign(new Error('session_closed'),{code:'session_closed'}));
    const request={jsonrpc:'2.0',id:++this.sequence,method,params};
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>this.fail('request_timeout'),this.requestTimeoutMs);
      this.pending.set(request.id,{resolve,reject,timer,request});
      try{this.child.stdin.write(JSON.stringify(request)+'\n');}catch{this.fail('stdin_failed');}
    });
  }

  notify(method,params={}) {
    if(this.failure)throw this.failure;
    if(this.closed||this.closing)throw Object.assign(new Error('session_closed'),{code:'session_closed'});
    try{this.child.stdin.write(JSON.stringify({jsonrpc:'2.0',method,params})+'\n');}catch{this.fail('stdin_failed');throw this.failure;}
  }

  async waitForClose() {
    if(this.closed)return true;
    let timer;
    const result=await Promise.race([this.finished.then(()=>true),new Promise(resolve=>{timer=setTimeout(()=>resolve(false),this.stopTimeoutMs);})]);
    clearTimeout(timer);return result;
  }

  stop() {
    if(this.stopping)return this.stopping;
    this.stopping=this.finish();return this.stopping;
  }

  async finish() {
    this.closing=true;
    if(!this.closed){try{this.child.stdin.end();}catch{this.fail('stdin_failed');}}
    if(!await this.waitForClose()){
      this.fail('shutdown_timeout');
      if(!await this.waitForClose()){
        this.child.kill('SIGKILL');
        if(!await this.waitForClose()){
          this.child.stdin.destroy();this.child.stdout.destroy();this.child.stderr.destroy();
        }
      }
    }
    if(this.failure)throw this.failure;
    if(!this.closed)throw Object.assign(new Error('unreaped_child'),{code:'unreaped_child'});
    return this.finished;
  }
}

module.exports={RPCSession};
