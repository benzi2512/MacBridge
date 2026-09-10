import Foundation

/// Read-only ChatGPT component. Embedded in the executable: no asset server,
/// dependency download, extra network listener, or second runtime.
enum ActivityWidget {
    // This component uses window.openai. Give each visible refresh a new ChatGPT
    // cache identity while preserving prior ChatGPT and MCP Apps card references.
    // All are fixed embedded resources, not a URI-to-file or network dispatcher.
    static let uri = "ui://macbridge/activity-chatgpt-v3.html"
    static let previousURI = "ui://macbridge/activity-chatgpt-v2.html"
    static let legacyURI = "ui://macbridge/activity-v1.html"
    private static let templates = [
        (uri: uri, mimeType: "text/html+skybridge", name: "macbridge-activity-chatgpt"),
        (uri: previousURI, mimeType: "text/html+skybridge", name: "macbridge-activity-chatgpt-v2"),
        (uri: legacyURI, mimeType: "text/html;profile=mcp-app", name: "macbridge-activity"),
    ]
    static var resourceDescriptors: [JSONObject] {
        templates.map { ["uri": $0.uri, "name": $0.name, "title": "MacBridge activity",
                         "mimeType": $0.mimeType] }
    }
    static func resourceContents(for requestedURI: String) -> JSONObject? {
        guard let template = templates.first(where: { $0.uri == requestedURI }) else { return nil }
        var meta: JSONObject = ["ui": ["prefersBorder": true,
                                       "csp": ["connectDomains": [], "resourceDomains": []]],
                                "openai/widgetDescription": "Read-only activity of the selected shared MacBridge runtime. Not ChatGPT reasoning. Pauses when hidden or on errors."]
        if template.mimeType == "text/html+skybridge" {
            meta["openai/widgetPrefersBorder"] = true
            meta["openai/widgetCSP"] = ["connect_domains": [], "resource_domains": []]
        }
        return ["uri": template.uri, "mimeType": template.mimeType, "text": html, "_meta": meta]
    }
    static var toolSpecs: [JSONObject] {
        func spec(_ name: String, _ description: String, render: Bool) -> JSONObject {
            var ui: JSONObject = ["visibility": ["model", "app"]]
            if render { ui["resourceUri"] = uri }
            var meta: JSONObject = ["ui": ui, "openai/widgetAccessible": true]
            if render { meta["openai/outputTemplate"] = uri }
            return ["name": name, "title": render ? "Show MacBridge activity" : "Read MacBridge activity",
                    "description": description,
                    "inputSchema": ["type": "object", "additionalProperties": false,
                                    "properties": render ? [:] : [
                                        "instance_id": ["type": "string", "maxLength": 36],
                                        "task_id": ["type": "string", "maxLength": 36]],
                                    "required": render ? [] : ["instance_id"]],
                    "annotations": ["readOnlyHint": true, "destructiveHint": false,
                                    "idempotentHint": true, "openWorldHint": false], "_meta": meta]
        }
        return [
            spec("bridge_activity_view", "Open a read-only activity card for this shared runtime: recent tool receipts and jobs, not ChatGPT reasoning or a chat-scoped feed. Requires observation enabled. UI availability depends on the host; tools remain usable without UI.", render: true),
            spec("bridge_activity", "Read bounded activity for the exact instance_id returned by bridge_activity_view. Optional task_id peeks at 4 KiB per log stream without consuming the job handle. No cancel, restore, file-content read or mutation. Cached snapshots are explicitly stale.", render: false),
        ]
    }

    // ChatGPT's documented compatibility bridge is deliberately feature-detected.
    // No fake connected state or DOM/browser automation fallback on another host.
    static let html = #"""
    <!doctype html>
    <html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    :root{color-scheme:light dark;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body{margin:0;background:transparent;color:light-dark(#252429,#f2f1f3)}
    *{box-sizing:border-box}
    #mb-activity{--line:light-dark(#e9e5e9,#3a363e);--muted:light-dark(#66616b,#b4afb9);--soft:light-dark(#faf7f8,#29252b);background:light-dark(#fff,#202023);border:1px solid var(--line);border-radius:18px;overflow:clip}
    header{display:flex;align-items:center;flex-wrap:wrap;gap:10px;padding:16px 18px}
    .mark{display:block;width:38px;height:38px;border-radius:11px;object-fit:contain}
    .brand{flex:1;min-width:160px}.brand strong{font-size:16px}.muted{color:var(--muted);font-size:12px}
    button,select{font:inherit;color:inherit;background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:7px 10px;cursor:pointer;max-width:100%}
    button:disabled{opacity:.6;cursor:default}button:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid light-dark(#b04653,#ffacbc);outline-offset:2px}
    .toolbar{padding:0 18px 14px;display:flex;flex-wrap:wrap;align-items:center;gap:8px}.toolbar label{margin-right:auto;display:flex;gap:6px;align-items:center}
    #mb-status{padding:10px 18px;border-block:1px solid var(--line);background:var(--soft);overflow-wrap:anywhere}
    #mb-status[data-error=true]{color:light-dark(#a12635,#ffabb3)}
    #mb-stats{display:flex;gap:16px;flex-wrap:wrap;padding:12px 18px;color:var(--muted);font-size:12px}
    .section{padding:0 18px 12px}.heading{margin:5px 0 8px;font-size:12px;color:var(--muted)}
    details{border-top:1px solid var(--line)}summary{cursor:pointer;min-height:44px;padding:10px 0;overflow-wrap:anywhere}
    pre{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--soft);border-radius:8px;padding:10px;white-space:pre-wrap;overflow-wrap:anywhere;margin:0 0 12px}
    #mb-jobs{width:100%;margin:6px 0 10px}#mb-empty{color:var(--muted);padding:8px 0}
    footer{border-top:1px solid var(--line);padding:10px 18px;color:var(--muted);font-size:11px;overflow-wrap:anywhere}
    @media(max-width:380px){header,.section,footer{padding-inline:12px}.toolbar{padding-inline:12px}.brand{min-width:130px}}
    </style></head><body>
    <section id="mb-activity" aria-label="Hoạt động MacBridge">
      <header><img class="mark" alt="" aria-hidden="true" src="data:image/png;base64,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"><div class="brand"><strong>MacBridge</strong><div class="muted">Hoạt động của runtime đang kết nối</div></div></header>
      <div class="toolbar"><label><input id="mb-auto" type="checkbox" checked> Tự cập nhật</label><button id="mb-refresh" type="button">Cập nhật</button></div>
      <div id="mb-status" role="status" aria-live="polite">Đang chờ dữ liệu từ ChatGPT…</div>
      <div id="mb-stats"></div>
      <div class="section"><div class="heading">Công việc · log gần nhất</div><label class="muted" for="mb-jobs">Chọn job để xem log</label><select id="mb-jobs"><option value="">Không đọc log</option></select><pre id="mb-log" hidden></pre></div>
      <div class="section"><div class="heading">Hoạt động gần đây · tối đa 24 mục</div><div id="mb-empty">Chưa có dữ liệu</div><div id="mb-history"></div></div>
      <footer><span id="mb-identity">Chưa xác định runtime</span><br>Chỉ đọc · Có thể gồm nhiều chat dùng chung MB · Không hiển thị suy nghĩ của ChatGPT</footer>
    </section>
    <script>
    (() => {
      'use strict';
      const el = id => document.getElementById(id);
      const root=el('mb-activity'), status=el('mb-status'), auto=el('mb-auto'), refresh=el('mb-refresh'), jobs=el('mb-jobs'), log=el('mb-log'), history=el('mb-history');
      let owner=null, latest=null, timer=null, inFlight=false, paused=false, fatal=false, disposed=false, visible=true, lastObserved=0;
      const setStatus=(text,error=false)=>{status.textContent=text;status.dataset.error=String(error);};
      const clear=()=>{if(timer!==null){clearTimeout(timer);timer=null;}};
      const active=s=>s?.busy || s?.jobs?.some(j=>j.running) || s?.history?.some(e=>e.state==='running');
      function schedule(){
        clear();
        if(disposed || paused || fatal || inFlight || !auto.checked || document.hidden || !visible || !owner || typeof window.openai?.callTool!=='function')return;
        timer=setTimeout(()=>poll(),active(latest)?3000:10000);
      }
      const text=(tag,value)=>{const node=document.createElement(tag);node.textContent=value;return node;};
      function render(s){
        if(!s || s.schema_version!==1 || typeof s.instance_id!=='string' || !Array.isArray(s.jobs) || !Array.isArray(s.history))throw new Error('Dữ liệu hoạt động không hợp lệ.');
        if(owner && owner!==s.instance_id){fatal=true;throw new Error('Runtime đã đổi. Mở lại thẻ để kết nối đúng instance.');}
        if(typeof s.observed_ms!=='number' || !Number.isFinite(s.observed_ms))throw new Error('Thiếu thời điểm quan sát.');
        if(s.observed_ms<lastObserved)return;
        owner=s.instance_id;lastObserved=s.observed_ms;latest=s;
        el('mb-identity').textContent=`${s.build_id} · instance ${owner.slice(0,8)}`;
        el('mb-stats').textContent=`${s.catalog_count} công cụ · ${s.jobs_known?s.jobs.filter(j=>j.running).length:'?'} job đang chạy · ${s.transaction_count??'?'} bản khôi phục${s.jobs_truncated?' · danh sách job rút gọn':''}`;
        const selected=jobs.value;
        jobs.replaceChildren(text('option','Không đọc log'));jobs.firstChild.value='';
        for(const job of s.jobs){const option=text('option',`${String(job.task_id).slice(0,8)} · ${job.running?'Đang chạy':`Đã dừng (${job.exit_code??'?'})`}`);option.value=job.task_id;jobs.append(option);}
        jobs.value=Array.from(jobs.options).some(o=>o.value===selected)?selected:'';
        log.hidden=!selected;
        if(selected){
          if(!jobs.value)log.textContent='Job không còn được giữ trong runtime.';
          else if(s.log_error)log.textContent=s.log_error;
          else if(s.log?.task_id===selected)log.textContent=`stdout (đuôi log, bỏ qua ${s.log.stdout_skipped_prefix_bytes??0} byte đầu):\n${s.log.stdout??''}\n\nstderr (bỏ qua ${s.log.stderr_skipped_prefix_bytes??0} byte đầu):\n${s.log.stderr??''}`;
          else log.textContent='Chưa nhận log cho job đã chọn.';
        }
        const opened=new Set(Array.from(history.querySelectorAll('details[open]')).map(d=>d.dataset.id));
        history.replaceChildren();el('mb-empty').hidden=s.history.length>0;
        el('mb-empty').textContent='Chưa có hoạt động được ghi nhận.';
        for(const event of s.history.slice(-24).reverse()){
          const detail=document.createElement('details');detail.dataset.id=event.id;detail.open=opened.has(event.id);
          const state={running:'Đang thực hiện',returned:'Đã trả kết quả',failed:'Gặp lỗi'}[event.state]??String(event.state);
          detail.append(text('summary',`${event.tool} · ${state}`));
          const lines=[];if(event.path)lines.push(`File: ${event.path}`);if(event.cwd)lines.push(`Thư mục: ${event.cwd}`);
          if(Number.isFinite(event.started_ms))lines.push(`Bắt đầu: ${new Date(event.started_ms).toLocaleTimeString()}`);
          if(Number.isFinite(event.finished_ms))lines.push(`Thời gian: ${Math.max(0,event.finished_ms-event.started_ms)} ms`);
          for(const [key,value] of Object.entries(event.result??{}))lines.push(`${key}: ${String(value)}`);
          detail.append(text('pre',lines.join('\n')||'Không có chi tiết bổ sung.'));history.append(detail);
        }
        const at=new Date(s.observed_ms).toLocaleTimeString();
        setStatus(s.snapshot_stale?`MB đang bận · dữ liệu job là bản lưu tạm · quan sát ${at}`:`Đã cập nhật ${at}${paused?' · Đã tạm dừng':''}`);
        schedule();
      }
      function fail(error){paused=true;clear();if(fatal)refresh.disabled=true;setStatus(error instanceof Error?error.message:'Không nhận được dữ liệu; đã tạm dừng cập nhật.',true);}
      async function poll(){
        clear();if(disposed || fatal || inFlight)return;
        if(document.hidden || !visible){schedule();return;}
        if(!owner){fail(new Error('Chưa có runtime ban đầu. Gọi bridge_activity_view trong chat để mở thẻ.'));return;}
        if(typeof window.openai?.callTool!=='function'){fail(new Error('Phiên này chưa cung cấp cầu nối UI. Số liệu hiển thị chưa phải cập nhật live.'));return;}
        inFlight=true;refresh.disabled=true;let expired=false;
        const watchdog=setTimeout(()=>{expired=true;fail(new Error('Chưa nhận phản hồi sau 20 giây; đang chờ lượt đọc này, không gửi chồng yêu cầu.'));},20000);
        try{
          const args={instance_id:owner};if(jobs.value)args.task_id=jobs.value;
          const result=await window.openai.callTool('bridge_activity',args);
          if(disposed || expired)return;
          if(result?.isError)throw new Error('MB từ chối lượt đọc. Đã tạm dừng; kiểm tra runtime/quyền trước khi thử lại.');
          render(result?.structuredContent);
        }catch(error){if(!disposed)fail(error);}finally{clearTimeout(watchdog);inFlight=false;refresh.disabled=fatal;if(!disposed)schedule();}
      }
      function accept(s){if(disposed || fatal)return;try{render(s);}catch(error){fail(error);}}
      refresh.addEventListener('click',()=>{if(inFlight || fatal)return;paused=false;poll();});
      auto.addEventListener('change',()=>{if(auto.checked){paused=false;schedule();}else{clear();setStatus('Đã tắt tự cập nhật · giữ số liệu lần đọc cuối.');}});
      jobs.addEventListener('change',()=>{if(!jobs.value){log.hidden=true;return;}log.hidden=false;log.textContent='Đang lấy đuôi log…';if(!paused)poll();});
      document.addEventListener('visibilitychange',()=>{if(document.hidden){clear();setStatus('Đang tạm dừng khi thẻ bị ẩn.');}else schedule();});
      if(typeof IntersectionObserver==='function'){
        const observer=new IntersectionObserver(entries=>{visible=entries[0]?.isIntersecting!==false;if(!visible)clear();else schedule();});observer.observe(root);
        window.addEventListener('pagehide',()=>observer.disconnect(),{once:true});
      }
      window.addEventListener('openai:set_globals',event=>{const globals=event.detail?.globals;if(globals?.theme)document.documentElement.style.colorScheme=globals.theme==='dark'?'dark':'light';if(globals?.toolOutput)accept(globals.toolOutput);else schedule();});
      window.addEventListener('message',event=>{if(event.source===window.parent && event.data?.jsonrpc==='2.0' && event.data.method==='ui/notifications/tool-result')accept(event.data.params?.structuredContent);});
      window.addEventListener('pagehide',()=>{disposed=true;clear();},{once:true});
      if(window.openai?.theme)document.documentElement.style.colorScheme=window.openai.theme==='dark'?'dark':'light';
      if(window.openai?.toolOutput)accept(window.openai.toolOutput);
      else if(typeof window.openai?.callTool!=='function')setStatus('Chờ host nạp UI và dữ liệu. Chưa có kết nối live.');
    })();
    </script></body></html>
    """#
}
