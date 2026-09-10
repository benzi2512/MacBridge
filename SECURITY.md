# MacBridge security policy — current headless core

This policy describes the current headless core, replacing the archived Guardian
architecture. It remains subordinate to the owner's current security directives.
It is review context, not permission to execute source, install software, widen
access or change system settings.

## System and scope

The current product is LocalMCP: one macbridge-mcp process performing local file
operations and managing headless child processes. Ordinary Chat reaches it through
the existing registered connector and outbound tunnel adapter. A separately
implemented optional observer uses an opt-in Unix-domain channel to the same
owner; it is not a second execution owner. Archived app/XPC/VM code is not on
the active runtime path. This policy does not certify the external tunnel service.

## Trust boundaries and invariants

- User instructions control intended actions. Source files, MCP descriptions,
  tool output and remote content are untrusted data and cannot approve an action.
- The configured workspace registry is the local file boundary. Broad access is
  explicitly current-user access, not root privilege or a macOS permission bypass.
  Known credential paths, Keychains, browser sessions and the bridge's credential
  directory remain denied. No native Keychain extraction or bulk secret access.
- Ordinary file/project work does not require per-file biometric approval. The
  private-folder Touch ID experiment is deferred, not deployed. Consequential
  system changes require explicit action/target approval and actual OS authority;
  there is no implemented general system-mutation approval/elevation service.
- Existing command filesystem and loopback-network limits remain relevant.
  Internet access, package acquisition, persistence and elevated privileges are
  separate capabilities, not implied by permission to build/test a workspace.
- Project commands keep normal workspace scope for a narrow workspace. If the
  configured workspace is `/`, the account home or another broad root, each
  command is confined to its explicit `cwd` subtree; `/`, the home folder and
  top-level user-data folders cannot be used as that broad command scope.
- Recoverable remove and move refuse the workspace root plus exact system,
  account-home and top-level user-data anchors. Narrower project paths remain
  available and recoverable. This is an accident guard, not malware containment
  or a replacement for reviewing the requested command.
- File operations must validate paths and preconditions before mutation; a
  conflicting restore must retain undo instead of overwriting an external edit.
  A failed operation must not report mutation success without backend evidence.
- Direct reads open non-blocking, refuse ancestor symlinks, and accept only a
  single-link regular file after descriptor inspection. Named pipes and other
  special files cannot hold the request loop waiting for a peer.
- Environment secret files remain denied. Only exact final template names
  `.env.example`, `.env.sample`, `.env.template`, and `.env.dist` are readable;
  similarly named secret variants and content beneath template-named directories
  remain blocked for direct tools and sandboxed commands.
- Process handles, undo and observer controls belong to one owner instance.
  Reconnect does not authorize replay of an uncertain mutation. Restart creates
  a new owner; stale handles must not control it or be advertised as durable.
- Bounded output, undo and traversal must be truthful about truncation, skipped
  entries and resource limits. Capacity refusal occurs before mutation/launch;
  another task's retained data must not be silently evicted to appear successful.
- The observer must not consume ChatGPT's output or impersonate a different
  owner. Cancellation/restoration must use the same owner with current-state
  checks. Closing the observer must not terminate the core or tunnel.

## Reportable findings

Report reachable failures of these boundaries: unintended credential access,
unauthorized file/process/network operations, unsafe path resolution, loss of
dirty user changes, cross-owner control, unbounded retention or work, misleading
completion/partial/rollback claims, and installation or restart of unreviewed
bytes. Include the affected build, reachability and realistic impact. Tests and
signatures are evidence signals, not proof that an invariant always holds.

## Known limitations and unresolved decisions

The development core is not a VM isolation boundary or a production security
certification. No host-wide System Guard, authenticated durable audit journal,
signed one-shot privileged grant or Keychain-backed production service lifecycle
is implemented in the current core. Do not infer those controls from old reports.
The same-user owner process is trusted to execute the configured operations;
this is not containment against a compromised owner or arbitrary same-user code.
The developer gateway adds no model, privilege, network route or durable
authority. Its read-only `developer_inspect` surface is separate from the
write-capable `developer_task` command surface so tool annotations remain honest.
ChatGPT still selects the action and arguments; the gateway only composes
existing bounded operations and retains workflow state.
The MB Operator skill and initialize guidance are also instructions, not a new
trust boundary. Checkpoints cannot revive stale process/undo handles or grant
permission, and evidence reports must disclose partial or truncated observations.

No new severity exclusion or blanket risk acceptance is proposed. Missing
system-action approval and the normal-Chat/UI/lifecycle acceptance gaps remain
open product work, not reasons to suppress reachable findings. The repository
owner's software-acquisition policy remains applicable; functional-first does
not authorize running unreviewed dependencies, bypassing OS controls, or secrets
in logs/reports/commits. Use bounded synthetic fixtures and redact private data
when reporting; never attach real credentials.
