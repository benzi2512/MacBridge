# MacBridge host binding and recovery contract

This contract separates what the MacBridge core can prove from what the ChatGPT host and tunnel adapter must prove. A healthy core process is not, by itself, evidence that a chat has callable tool schemas.

## Identity and binding

Initialize and MCP discovery/tool-list metadata expose the camel-case field `bindingEpoch`; tool-call results such as `bridge_capabilities` and `bridge_diagnostic` expose `binding_epoch`. Both represent the same value, derived from the runtime instance and exact catalog digest. Hosts must treat a changed epoch as a new binding and discard cached callable schemas from the previous epoch.

After connect or reconnect, the host must resolve and successfully call all of the following under the same epoch:

1. `bridge_capabilities`
2. `workspace_overview`
3. `file_stat` against an approved fixture
4. `file_read` against an approved fixture

If any schema is missing, the correct state is `HOST_BINDING_MISSING`, not “MacBridge is healthy.” The host should perform one fresh schema discovery/rebind, then run the probe again. Mutations must remain disabled until the probe passes.

## Catalog changes

The core advertises `tools.listChanged=true`. A host that observes a new `catalog_sha256` or `binding_epoch` must reload the tool list. The full catalog and every exact schema remain available through MCP `tools/list`; `tool_catalog` is a bounded lookup helper and does not grant authority.

## Tunnel state

`bridge_diagnostic` reports only core-observable state. For a Web tunnel, `CONNECTED_TO_CORE_HOST_STATE_UNKNOWN` means the core received the call but cannot inspect the host's schema registry or the tunnel provider's control plane.

The tunnel adapter is responsible for:

- reconnect with bounded exponential backoff and jitter;
- a single in-flight rebind attempt per connection generation;
- no automatic replay of mutations with an unknown outcome;
- retaining the last failure class and transition time for owner diagnostics;
- rerunning the read-only binding probe before declaring the connector ready.

## Safe recovery sequence

1. Preserve owner state, retained processes, and undo transactions.
2. Reconnect transport without replacing the core owner.
3. Rediscover schemas and compare `binding_epoch`.
4. Run the four read-only probes above.
5. Resume reads first; resume mutations only after all probes pass.
6. If the epoch changed, never reuse process, transaction, or work control tokens from the old owner.

Restarting the shared core is a maintenance action, not a normal reconnect step. It requires all retained work and undo state to be classified first.
