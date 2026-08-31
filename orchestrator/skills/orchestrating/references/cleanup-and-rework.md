# Cleanup and rework

Read this file before any child/parent collection, task-window archival, rework
reprovision, or cleanup retry.

## Batch child collection after all tasks integrate

Batch child collection begins only after every approved task is completed and
integrated into the parent. Until then, every integrated child worktree, branch,
report, and task window remains intact.

Then run one mission-scoped GC pass to collect all integrated children.
Require every task to reach `collected`, then archive every accepted child window
only after the batch collection has completed. If any child fails collection or
archival, retain the mission in `cleanup_pending`; do not start selected-backend review with
a partially collected batch. Once all children are collected and archived,
resume the same accepted planning/review session without another user gate.

## Child collection

The durable child lifecycle is `ready -> running -> completed -> integrated -> collected`;
only exact authority advances it. GC and reprovision share one shared coordinator lifecycle mutation lock.

GC consumes only coordinator manifests and integration records. It requires the
parent to contain the recorded integration and child tips, a clean exact child
worktree on its exact branch, matching local/remote refs, current generation,
and unchanged manifest hash. It removes only that worktree and local ref; a
remote ref is deleted only after exact-tip verification with a lease.

Before deletion, publish and fsync cleanup intent and journal records. Always
revalidate the exact generation and manifest immediately before every destructive boundary and
state publication. Drift, dirt, missing evidence, network failure, or lock
contention produces durable `cleanup_pending` and preserves resources. Repeated
collection is idempotent.

## Task-window archival

After verified batch integration and Git collection, archive the exact accepted child thread.
Never archive running, blocked, review, or unresolved-rework tasks.
Use Codex task APIs when available; from Claude Code use
`codex-task-client.py archive --thread-id <id>` and `unarchive --thread-id <id>`.
Record successful or authoritative already-archived results once. Any other API
failure records `task-window archive failure`, writes
`task-window-archive-pending`, journals the reason, and retains
the ID for Phase 0 retry. Archive state is hygiene, never completion evidence.

## Rework

Map each selected-reviewer finding to the task owning its files/contracts. Stop after three
nonconverging review rounds.

For each affected task:

1. require its prior generation integrated, collected, and task window archived;
2. unarchive the exact accepted child thread and verify visibility;
3. run `task-worktree.sh reprovision` with its exact retained paths, sandbox,
   current generation via `--expected-generation`, and updated parent tip;
4. publish matching coordinator/worker authority at generation `N+1`;
5. write a bounded task-local rework prompt; and
6. use native `send_message_to_thread` to the same ID.

Never send against a collected/missing worktree or create a replacement owner.
After brokered fixes and verification, reintegrate and recollect. Rearchive only after verified reintegration and exact worktree and branch collection, using the
same thread before selected-backend re-review.

### Reprovision crash recovery

Incomplete rollback must preserve reprovision-intent, staging, and backups.
Before replacing authority, fsync intent, stage, and backup contents plus their
directories. An exact retry may recognize an already-converged reprovision epoch
only from an fsynced reprovision completion receipt that binds old/new
generation, base/tips, paths, accepted thread, sandbox, hashes, strict one-row manifests and one-line scalar authorities.
A stale receipt never authorizes a newer epoch.

## Parent collection

After resolved review and merged-tree verification, publish the exact parent
manifest, target snapshot, `review-resolution=resolved`, decisions, and
verification. Set mission state `accepted` before collection. Run only:

```text
scripts/orchestrator-gc.sh --hub <hub> --mission <mission> --clean
```

Collection requires every child collected and archived, exact parent tip
contained in the target, a clean exact parent worktree, and the frozen four-file
approval manifest. PR metadata may corroborate but never replace ancestry.
Archive design, plan, DAG, decisions, plan/status HTML, Sites delivery receipt,
report, verification, and cleanup journal before removing planted settings,
worktree, local mission ref, and exact-tip remote ref.
Never delete or edit the target branch.

Archive the mission directory only after parent cleanup state is `collected`.
On `cleanup_pending`, preserve the accepted mission in place and retry this same
mission scope. Phase 0 hub discovery is report-only; unrelated cleanup warnings
never block new work or trigger an authorization question.
