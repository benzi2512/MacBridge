# Checkpoint and evidence contract

Use these fields as a compact contract, not as a transcript or workflow engine.

## Checkpoint

Create a checkpoint only for a long, paused, or handed-off task. Store it at an
explicit task-owned path in the active workspace and report that path. Do not
commit it unless requested.

```yaml
version: 1
outcome: short requested outcome
acceptance: observable checks still required
workspace_id: registered MacBridge workspace ID
root_hint: non-sensitive workspace-relative context
work_id: retained parent task ID, if any
processes:
  - task_id: retained process ID
    stdout_cursor: last consumed cursor
    stderr_cursor: last consumed cursor
transactions: task-owned restore IDs still needed
verified:
  - claim: what was independently checked
    evidence: bounded result or receipt reference
unknowns: unresolved or truncated observations
next_step: one concrete continuation step
```

On resume, confirm the workspace and current runtime owner/build, then re-read
process and transaction state. A checkpoint does not prove a handle survived a
restart and cannot authorize work.

## Evidence report

Keep the final report short but explicit:

```yaml
outcome: completed, partial, failed, or blocked
changes: files or state actually changed
verification: tests, readback, and diff checks with observed outcomes
errors: relevant failures and whether they were resolved
receipts: task, process, and transaction IDs still useful to the owner
truncation: dropped bytes, bounded previews, incomplete scans, or none
unknowns: claims not independently established
remaining: next action, or none
```

Reference retained logs instead of copying large output. Never omit a failed
batch item, non-zero exit, partial traversal, or truncated stream merely because
another check passed.
