# Cleanup and rework

Read this file before any child/parent collection, task-window archival, rework
reopen, or cleanup retry.

## Batch child collection after final review

Every child worktree, branch, report, and visible task window remains intact
through selected-backend review and all rework rounds. Integration of the last
DAG node is not cleanup authority: review may still route a finding back to the
same child context.

Only after final review is durably resolved, merged-tree verification succeeds,
and mission state is `accepted`, archive every accepted child window as one
batch. Native archive is the worktree-release boundary and may remove the
host-owned worktree. After all windows are archived, run one mission-scoped GC
pass to verify/remove any exact residual worktree and task refs and require every
task to reach `collected`. If archival or collection fails, keep the accepted
mission in place, record task and parent cleanup authority as `cleanup_pending`,
and exact-retry it.

## Child collection

The durable child lifecycle is `ready -> running -> completed -> integrated -> collected`;
only exact authority advances it. Review reopens an integrated retained child;
it does not recreate a Git worktree or task window.

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

After clean final review and acceptance, archive the exact accepted child thread
before Git collection.
Never archive running, blocked, review, or unresolved-rework tasks.
Use Codex task APIs when available; from Claude Code use
`codex-task-client.py archive --thread-id <id>`. A successful native archive is
terminal for that child; never unarchive it after the host releases its
worktree.
Record successful or authoritative already-archived results once. Any other API
failure records `task-window archive failure`, writes
`task-window-archive-pending`, journals the reason, and retains
the ID for Phase 0 retry. Archive state is hygiene, never completion evidence.

## Rework

Map each selected-reviewer finding to the task owning its files/contracts. Stop after three
nonconverging review rounds.

For each affected task, require its prior generation integrated, its exact child
worktree still clean and registered, and its task window still unarchived. Run:

```text
scripts/task-outcome.py reopen \
  --control-dir <control-dir> --task-dir <task-state-dir> \
  --task-id <task-id> --parent-worktree <parent-worktree> \
  --expected-generation <N>
```

The coordinator operation verifies the accepted thread, exact task-state-dir,
matching one-row manifests, clean registered child worktree and branch, prior
integration authority, and that the current parent still contains that
integration. It advances the retained authority to generation `N+1`, refreshes
the coordinator-owned outcome nonce, and converges both generation and state
copies to `ready`. It retains the outcome ledger, worktree, branch, and accepted
thread. An old or delayed outcome therefore fails its generation/nonce binding.

After successful reopen, write a bounded task-local rework prompt and use native
`send_message_to_thread` to the same ID. Never collect, archive, unarchive, hand
off, or replace the owner between review and rework. After brokered fixes and
verification, reintegrate, then keep the child intact through selected-backend
re-review.

An accepted child that returns BLOCKED, FAILED, a permission denial, or a broker
rejection keeps the same thread and worktree. Import its bound outcome before
any mediation or retry. Only a genuine pre-adoption native launch/identity
health failure may use the one replacement allowance. Never unarchive, handoff,
or resume an archived rejected bootstrap; its native worktree may already be
gone.

### Retained rework crash recovery

Before changing any live scalar, `reopen` publishes and fsyncs one durable
rework intent that binds the old/new generation and nonce, accepted thread,
task-state directory, manifest hash, worktree/branch/repository, prior child and
integration tips, and observed parent tip. While that intent exists, outcome
publication is refused.

An exact retry finishes any mixed old/new scalar set only when every value is
one of the two intent-bound values and all retained Git/integration authority
still matches. Completion publishes the immutable
`rework-completion-<N+1>.json` receipt before clearing the intent. That receipt
allows only the exact old-generation retry; a stale receipt never authorizes a
newer epoch.

## Parent collection

After resolved review and merged-tree verification, publish the exact parent
manifest, target snapshot, `review-resolution=resolved`, decisions, and
verification. Set mission state `accepted` before collection. Run only:

```text
scripts/orchestrator-gc.sh --hub <hub> --mission <mission> --clean
```

Collection requires every child archived and collected, exact parent tip
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
