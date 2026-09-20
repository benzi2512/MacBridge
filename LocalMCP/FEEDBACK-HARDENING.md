# Feedback hardening implemented in 0.4.0

This candidate addresses the reliability gaps observed during real SEO and long-running work while preserving the existing workspace, credential, process, and owner boundaries.

- Stable host binding: `binding_epoch`, catalog change notification, and an honest `bridge_diagnostic` contract.
- Structured errors: stable codes, layer, retry guidance, operation outcome, and current revisions for CAS/create-only conflicts.
- Safer writes: `create_only`, pre-publication revision checks, alias rejection, coordinated `file_write_many` with verified content/POSIX-mode compensation, one composite undo receipt, pre/post hashes, and work grouping. The batch is not claimed to be crash-atomic or isolated from unrelated writers; compensation does not preserve inode identity, extended attributes, ACLs or other filesystem metadata.
- Consistent reads: optional snapshot-consistent `file_read_many`, `workspace_resolve`, and `project_read_bundle`.
- Structured mutation: bounded JSON Pointer patching with exact SHA-256 CAS.
- Durable outputs: content-addressed `artifact_snapshot` with create-only publication.
- Scheduled work: owner-local fired → worker_started → result_ready → persisted → acknowledged lifecycle; persisted requires a retained work-owned write transaction matching the current artifact, and completion is refused before acknowledgement. This state is not durable across owner restart.
- Transaction UX: recoverability, reload blocking, retained counts, work IDs, and richer receipts.
- Local presentation: fixed Finder, Preview and TextEdit actions only; browsers,
  URLs and arbitrary handlers remain blocked. Local HTML opens as text in TextEdit.
- Browser and general computer-control surfaces are not part of this candidate.

The host/tunnel control plane is outside this source target. Its required reconnect and schema-rebind behavior is specified in `HOST-BINDING-RECOVERY.md` and remains a cutover acceptance gate.
