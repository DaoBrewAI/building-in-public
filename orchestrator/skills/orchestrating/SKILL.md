---
name: orchestrating
description: Run Hybrid Codex-orchestrated missions in which Claude Fable-5 brainstorms, plans, and independently reviews while Codex GPT-5.6-Sol performs every implementation and rework change. Use when the user asks to orchestrate work, launch an autonomous mission, or resume missions from a .orchestrator hub.
---

# Orchestrating Hybrid 0.4 Missions

Act as the Codex coordinator. Each new mission is a staged pipeline across two
resumable backends: the same headless Claude Fable-5 session owns brainstorm,
plan, and review; bounded Codex GPT-5.6-Sol child threads each own one approved
implementation task, its verification, rework, and brokered commit requests.
State and handoffs live on disk so the coordinator stays free between wakes.

## Fixed backend ownership

- Mission backend contract: brainstorm, plan, and review use claude-fable-5;
  ALL code implementation uses gpt-5.6-sol. Fable is a preference for the Claude
  stages, not a hard gate: when it runs out of capacity, fall through to
  claude-opus-5 automatically (see the quota rule below). Implementation never
  moves off Codex under any circumstance.
- **Quota fallback is automatic — never a question for the user.** When a
  plan/review spawn dies because the model ran out of capacity — in whatever
  form the provider expresses it: a nonzero exit, an error flag, a refusal
  naming a limit, a reset time, a prompt to buy credits, or wording nobody has
  seen before — judge the meaning and treat it as a quota wall rather than a
  crash. You are a model reading a message; do not pattern-match a phrase list.
  (`spawn-worker.sh` exits 75 when its own matcher catches it, but that matcher
  is a convenience, never the thing you rely on.) Then: respawn the same stage
  immediately with `ORC_PLAN_MODEL=claude-opus-5` prepended, record
  `quota-fallback: <date> <stage> fable→opus` in the mission notes and once in
  DECISIONS.md, and tell the user in one line only AFTER the work is moving. It
  is not a crash strike. The override is per-spawn and never persisted, so later
  stages return to Fable once capacity is back. Park the mission only if the
  fallback model is exhausted too, naming which quota needs topping up.
- Brainstorm, plan, plan revision, review, and re-review:
  `claude -p --model claude-fable-5 --effort high`.
- **ALL code implementation, fixes, tests that require writes, and commits happen
  in the exec stage on gpt-5.6-sol** with high reasoning.
- The same Fable session plans and reviews. Each child Codex thread implements
  one approved task and handles only that task's rework rounds.
- Fable stages are read-only on worktrees. The guard blocks worktree writes and
  `git commit`; findings enter `state=rework` and return to Codex.
- Codex runs in `workspace-write` with only mission worktrees and the mission
  directory writable, network off by default. A trusted commit broker converts
  `COMMIT-REQUEST-<n>.json` files into commits.
- Branches are `orc/<mission-slug>`. Missions sharing a repo run in PARALLEL by
  default — isolation is per-worktree, not per-repo. Queue only on a real
  dependency (see Phase 2).

## Resolve paths and hub

Derive `PLUGIN_DIR` from this loaded file by moving from
`skills/orchestrating/SKILL.md` up two directories. Before provisioning, require
these executable shared 0.4 assets:

- `$PLUGIN_DIR/scripts/spawn-worker.sh`
- `$PLUGIN_DIR/scripts/provision-preflight.sh`
- `$PLUGIN_DIR/scripts/pipeline-gate.sh`
- `$PLUGIN_DIR/scripts/worker-guard.sh`
- `$PLUGIN_DIR/scripts/commit-broker.sh`
- `$PLUGIN_DIR/scripts/orchestrator-gc.sh`
- `$PLUGIN_DIR/scripts/classify-mission-version.sh`
- `$PLUGIN_DIR/scripts/validate-task-dag.sh`
- `$PLUGIN_DIR/scripts/task-worktree.sh`
- `$PLUGIN_DIR/scripts/integrate-task.sh`
- `$PLUGIN_DIR/scripts/codex-task-client.py`

The hub is the nearest ancestor of cwd already containing `.orchestrator/`, or
cwd on first use. Create `.orchestrator/missions/`, `control/`, `archive/`,
`DECISIONS.md`, and `MEMORY.md`. Call the directory `$HUB`. A mission's
coordinator-owned control directory is `$HUB/control/<mission-slug>/`; it must
stay outside every worker-writable root.

### Legacy Codex 0.2 compatibility

Do not silently migrate an in-flight 0.2 mission. Treat it as legacy when its
session has `backend: codex-exec`/`worker_pid:` with no append-only `stage:`
history, OR when it is pending with the 0.2 MISSION shape (one `Brief:`, the
`gpt-5.6 (overrideable)` session spec, or a flat `.worktrees` control file) and
no Hybrid pipeline marker (`request.md` plus `Briefs:`). This includes an
old pending mission that has no session.txt yet. Reconcile and resume it with
`$PLUGIN_DIR/codex-scripts/spawn-worker.sh`, its trusted control manifest, and
the old state vocabulary. New missions always use the Hybrid 0.4 shared
`scripts/` and `templates/` paths. Never mix launchers inside one mission.

### Hybrid 0.3 single-executor compatibility

Do not silently migrate an in-flight Hybrid 0.3 mission into the 0.4 task DAG.
Before state routing, invoke `$PLUGIN_DIR/scripts/classify-mission-version.sh`
with the exact coordinator mission and control directories. New 0.4 missions
have a strict coordinator-owned `pipeline-version` authority containing
`0.4.0`; existing 0.3 missions predate that marker. Classify an unmarked mission
as Hybrid 0.3 only when its mission/session shape has the shared Hybrid marker
(`request.md` plus `Briefs:` and append-only stage history) and
`approved-task-dag.json and the coordinator task registry are both absent`.
The recorded `codex_thread_id` is required before resuming exec/rework but may
be absent at the 0.3 planned go gate. A partial or contradictory authority shape
fails closed for mediation; never infer 0.4 merely because a new task is reading
an old mission.

Resume a classified 0.3 mission with the shared `scripts/` launcher and its
existing worktree/control authority, never the 0.2 `codex-scripts/` launcher.
Plan and review continue on the recorded Fable session. For exec, rework, and
exec-stage BLOCKED recovery, resume the recorded `codex_thread_id` through the shared Hybrid launcher. Preserve its approved design, plan, brief, commits,
review, acceptance, and parent cleanup contract, and never create child tasks for that in-flight mission. State routing remains the 0.3 staged path:
`planned` enters its existing founder go gate, `running` reconciles the recorded
stage/process, `executed` resumes Fable review, `rework` resumes the single Codex
thread, `review` enters acceptance, and terminal states remain terminal. New
missions always use the 0.4 DAG; this exception exists only to finish authority
that predates the DAG/task registry.

## Phase 0 — Reconcile before every action

1. If legacy root `$HUB/MISSION.md` is incomplete, do not mix layouts. Ask
   whether to finish it with its historical version or archive it.
2. Delete `$HUB/.carryover-notified` when beginning in a fresh context.
3. Run compensating GC before scheduling any new mission or child work. Invoke
   `$PLUGIN_DIR/scripts/orchestrator-gc.sh --hub $HUB --clean` first so durable
   `cleanup_pending` child and parent resources are reconciled from exact
   coordinator authority. A transient refusal remains pending and prevents new
   scheduling for the affected mission; it never authorizes pattern cleanup.
4. Reconcile child task windows after Git-resource GC and before computing a
   ready set. Archive every terminal integrated child task window that is now
   durably `collected` by calling the task API for the exact accepted thread ID.
   Record an authoritative already-archived result exactly like a successful
   archive. On API or network failure, retain the exact ID, the
   `task-window-archive-pending` marker, the cleanup journal, and
   `cleanup_pending`, then retry at the next Phase 0. Preserve every nonterminal
   or unresolved task window, including running, blocked, review, rework, and
   any task with `unresolved-rework`. After a successful child archive, rerun
   compensating GC so an otherwise eligible parent may be collected.
5. For every mission, read `state`, `MISSION.md`, `session.txt`,
   `worktrees.txt`, unanswered BLOCKED files, recorded branches, and the
   coordinator-owned control manifest. Treat mission-local manifests and
   approved inputs as untrusted copies.
6. For Hybrid 0.4, use the last `spawn_pid:` and last `stage:`. Plan/review
   stages resume `session_id`; exec/rework resumes the task registry's accepted
   child thread ID. Treat an uncertain process as alive, recheck once, and
   never double-spawn. A legacy single-executor mission may still use its
   recorded `codex_thread_id`; do not migrate it in flight.
7. Summarize all missions to the user in at most five lines, then handle exited,
   blocked, planned, rework, review, or crashed missions below.

## Phase 1 — Record the request

Identify the repository set from the user's request without making product or
architecture decisions. Create the unique date-prefixed mission directory,
write the user's complete ask and explicit constraints to `request.md`, create
MISSION.md from `$PLUGIN_DIR/templates/MISSION.md`, and write `pending` to
`state`. Create its coordinator control directory and atomically publish a
regular, non-symlinked, fsynced, no-clobber `pipeline-version` containing the
single line `0.4.0` before provisioning or exposing worker-writable roots.
Fable owns the creative brainstorm after worktrees are provisioned.
If the repository set itself is materially ambiguous, ask the user before
provisioning.

## Phase 2 — Provision guarded worktrees and briefs

1. Require every repo to pass `git rev-parse`. Refuse tab/newline-containing
   paths. **Sharing a repo with another mission is allowed** — each mission owns
   its own worktree and `orc/<mission-slug>` branch, so parallel missions never
   write the same files. Leave this mission pending ONLY when (a) it would reuse
   a worktree or branch another mission owns, or (b) a real output dependency
   exists: it builds on the other's unmerged commits, edits the same files or
   module in a way that collides at merge, changes or consumes a contract the
   other side owns, or its verification only makes sense after the other lands
   (two migrations in one repo collide on the revision chain — sequence those).
   Name the blocking mission and the reason when you queue. Otherwise launch in
   parallel and say so. If you cannot name the concrete artifact one mission
   needs from the other, there is no dependency; when genuinely unsure whether
   two will collide at merge, ask the user rather than serializing by reflex.
2. Create `<umbrella>/.worktrees/<mission-slug>/<repo-name>` on
   `orc/<mission-slug>`. Record tab-separated
   `<worktree> <branch> <base-sha> <repo>` rows in
   `$HUB/control/<mission-slug>/worktrees.txt`, copy it byte-for-byte to the
   mission's worker-facing `worktrees.txt`, and record rows in MISSION.md. Never
   use the worker-facing copy as commit authority.
3. The first repo is primary. Preserve any shared `.claude/settings.json`
   byte-for-byte: it may enable project plugins and policies needed by the
   mission.
4. Run `$PLUGIN_DIR/scripts/install-worker-settings.sh` for the primary
   worktree with `$PLUGIN_DIR/templates/worker-settings.json`, the colon-joined
   worktrees, mission directory, coordinator-owned control directory,
   `$PLUGIN_DIR/scripts/worker-guard.sh`, and
   `$PLUGIN_DIR/scripts/pipeline-gate.sh`. It renders the hooks into
   `.claude/settings.local.json`, adds that path to the worktree's local Git
   exclude, freezes its SHA-256 in coordinator-owned control state for the
   launcher to verify before every Fable turn, validates the JSON and hook
   paths, and fails closed rather than overwrite a pre-existing local settings
   file or follow a symlinked `.claude` directory. Never edit the shared
   settings to install mission hooks.
5. Copy the report template. Render the Fable brainstorm/plan/review brief from
   `$PLUGIN_DIR/templates/brief-codex.md` to mission `brief.md`. Render the Codex
   executor brief from `$PLUGIN_DIR/templates/brief-exec.md` to
   mission `brief-exec.md`. Fill all placeholders, including `CONTROL_DIR` and a
   control-directory `REVIEW_DIFFS` path. Fable may update its own brief only
   through a logged crash-respawn addendum before go; the executor never reads
   worker-writable approved inputs.
6. Run `$PLUGIN_DIR/scripts/provision-preflight.sh --mission-dir <dir>
   --worktree <primary> [--worktree <other>]...`. It installs dependencies,
   prepares in-worktree caches, and writes `baseline-attestation.json`. Never
   launch over an unadjudicated red baseline; record accepted pre-existing or
   sandbox-only failures in DECISIONS.md and the executor brief.

## Phase 3 — Launch Fable brainstorm + plan

Write `running` before spawning, then launch the shared worker in a background
terminal process whose exit can wake the coordinator:

```text
$PLUGIN_DIR/scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --worktree <primary> [--worktree <other>]...
```

The fresh Fable session invokes `10x-engineer:brainstorming`, writes design.md,
invokes `10x-engineer:writing-plans`, writes plan.md and plan-review.html, sets
state=planned, and exits. Update MISSION.md and board.html, tell the user it is
running, and remain available for other work.

## Phase 3g — Founder go gate

`state=planned` is the only planned human pause. Require `design.md`, `plan.md`,
and `plan-review.html`. Show the review HTML with a concise note covering the
mission, repos, and riskiest choice, then ask for explicit **go**.

If the user requests changes, resume the same Fable session so it updates
design.md first, then plan.md and plan-review.html:

```text
$PLUGIN_DIR/scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --worktree <primary> [--worktree <other>]... \
  --stage plan --resume "<founder correction>"
```

On go, first apply the compatibility classifier above. A classified in-flight
0.3 mission retains its three-file approved contract and continues through its
single recorded Codex thread; it does not enter the child protocol below.

For a 0.4 mission, atomically snapshot mission `design.md`, `plan.md`, and the
fully rendered `brief-exec.md` into the coordinator-owned control directory as
`approved-design.md`, `approved-plan.md`, and `brief-exec.md`. Record their
SHA-256 hashes in `approved.sha256`, then invoke the exact freeze operation:

```text
$PLUGIN_DIR/scripts/validate-task-dag.sh --freeze \
  <mission-dir>/task-dag.json $HUB/control/<mission-slug>
```

The freeze must validate the staged DAG against the current three-file hash
authority, atomically publish `approved-task-dag.json`, and extend
`approved.sha256` with its hash. Verify all four approved files and the exact
four-entry hash manifest are regular, non-symlinked, outside worker roots, and
hash-valid. These frozen files are the only approved contract. Only after that
verification may the coordinator write `running` and enter the child-thread
protocol below. A missing, invalid, overlapping, cyclic, changed, or partially
published DAG remains `planned` and must not create a child task.

## Coordinator child-thread protocol

Scheduling depth is exactly coordinator -> mission -> child task. Only the
coordinator computes the ready set, creates child threads, records ownership,
integrates verified commits, and collects child resources. Mission child
threads never create grandchildren and never schedule, replace, or resume
another task.

The durable child lifecycle is `ready -> running -> completed -> integrated -> collected`.
Only the coordinator advances `completed` to `integrated` after exact manifest
and verification checks, and only exact resource GC advances `integrated` to
`collected`. `cleanup_pending` is a retriable cleanup overlay: it records the
last safe terminal step plus a cleanup-journal reason and retains every exact
authority record needed for retry. It never makes a task dependency-ready and
never authorizes integration or deletion by itself.

### Compute the ready set

Use only the coordinator-owned, frozen task DAG and task registry. A task is
ready only when:

- every predecessor is durably completed and verified integrated;
- it has no active or completed owner;
- it has no file or contract conflict with another running or ready task; and
- it has no user-approval blocker.

Reconcile every durable child outcome without treating completion alone as
readiness. Recompute the ready set after every verified integration and before
scheduling any dependent task; do not infer completion or integration from
chat text or process silence. Tasks outside this ready set are not eligible for
thread creation.

### Create and accept child threads

For every eligible, file-disjoint native 0.4 task, first invoke the production
lifecycle gate with the complete exact authority:

```text
$PLUGIN_DIR/scripts/task-worktree.sh create \
  --create-mode native-0.4 \
  --mission-dir <exact-mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --task-dir <exact-task-state-dir> \
  --mission <mission-slug> \
  --task-id <task-id> \
  --repo <exact-repository-worktree> \
  --parent-worktree <exact-parent-mission-worktree> \
  --worktree <exact-child-worktree>
```

This locked production gate, not a locally reimplemented ready-set helper,
must succeed before rendering or creating the Codex child thread. It validates
the classified native version, frozen exact four-entry approval manifest,
exact DAG node, predecessor integration, blockers, ownership, and active
file/contract conflicts before publishing child authority. Never create or
health-check a provisional task thread when this command refuses. A separately
classified compatibility invocation, where legacy child provisioning is
actually applicable, must explicitly use `--create-mode legacy` with the exact
mission and control directories; omission of the mode is never a legacy
fallback and native 0.4 authority can never take that path.

Only after successful production worktree creation, the coordinator renders
`templates/task-brief.md` with the exact approved task, declared files,
verification commands, child worktree, task state directory, frozen contract
paths, sandbox roots, and commit-broker path.

Resolve the intended Codex project context with `list_projects`. Match the exact
canonical repository path recorded in the coordinator manifest; do not choose
by label, title, summary, or a nearby ancestor. Desktop-local `local-*` project
IDs are not App Server project IDs and must not be passed through blindly. Pass
`--project-id` only when App Server `project/list` returns the exact matching
project; otherwise omit it and require post-create `list_threads` evidence to
bind the exact thread ID, cwd, Git identity, and intended project context. An
ambiguous or mismatched result is a coordinator BLOCKED outcome. Native 0.4
must never fall back to `codex exec`, because non-interactive exec sessions are
not user-visible project task windows.

Start the task-local commit broker, then launch the visible child with the App
Server client as the last foreground process in the tracked exec session:

```text
$PLUGIN_DIR/scripts/codex-task-client.py create \
  --cwd <exact-child-worktree> \
  --task-dir <exact-task-state-dir> \
  [--project-id <exact-app-server-project-id>] \
  --title "ORC <mission> · <task-id> <task-title>" \
  --model gpt-5.6-sol \
  --effort high \
  --prompt-file <exact-rendered-task-brief>
```

This client uses App Server `thread/start`, `thread/name/set`, and `turn/start`.
Its exact runtime workspace roots: the child worktree and task state directory.
It keeps the child worktree as `cwd`, grants workspace-write only to that
worktree plus the task state directory, and keeps network access disabled.
Create fresh project-local Codex threads rather than forks or hidden exec
sessions. A child owns exactly one task and one manifest-recorded worktree.

Treat every returned thread ID as provisional. Accept and record it only after
the continuation health check proves all of the following:

1. thread creation returned an ID and `list_threads` must find that exact ID
   with the exact intended title, cwd, and Git/project context; `read_thread`
   is supporting health evidence and never substitutes for task-list visibility;
2. setting the title succeeded, or a read confirms it is already correct;
3. the first turn exists and its status is active or completed normally;
4. recent items provide startup evidence that the child began reading its task
   brief, frozen contract, or project files; and
5. requested model, reasoning, service-tier, fast-mode, sandbox, writable-root,
   and commit-broker settings are recorded, with any unobservable setting
   explicitly marked unverified.

Only after all checks pass may the coordinator add the thread ID and owner to
the authoritative task registry and expose it in mission handoff/status files.
Publish the exact accepted thread ID as a strict one-line, fsynced scalar in
both the coordinator task authority and its separate worker-facing authority
copy; the coordinator copy remains authoritative, and later reprovision must
require the two values to match before issuing a completion receipt.
On a failed, invisible, or unreadable health check, stop the tracked provisional
turn, archive its exact ID when the task API can authoritatively identify it,
remove or mark stale any provisional record, and allow at most one replacement
from the same current durable brief. Never accept a thread merely because the
App Server client or `read_thread` can read it.
If that one replacement also fails, write a coordinator BLOCKED outcome; never loop replacements, fall back
to `codex exec`, or let a child replace itself.

### Consume durable child outcomes

The task directory's durable task state, `report.md`, `BLOCKED-<n>.md`, commit
broker results, and coordinator registry are the outcome contract. The
coordinator may use list/read calls only for health and liveness; scheduling,
integration, review, recovery, and continuation must not depend on reading the
full child chat. A completed child must record its exact changed files, branch,
base and tip SHAs, verification commands and raw results, commit-broker result,
deviations, and unresolved risks before setting its task state to `completed`.
A blocked child writes the next durable BLOCKED file and sets its task state to
`blocked` before ending. Preserve the child's exact sandbox roots and require
all commits through the existing commit-broker boundary.

Do not poll or inspect a healthy child mid-run. Reconcile its durable outcome
when the task reaches a terminal state or a tracked wake fires. After each
verified integration, recompute the ready set; when every task is integrated,
set the parent mission to `executed` and enter Fable review.

### Integrate and collect a completed child

Run `scripts/integrate-task.sh` only from the coordinator with the exact
coordinator control directory, task directory, mission/task identities, parent
worktree, and current expected parent tip. It verifies `completed`, the exact
one-row coordinator manifest, `orc-task/<mission>/<task-id>`, the recorded
base, exact child and parent tips, clean worktrees, child-tip and parent-tip
verification attestations, a durable report, and no unresolved rework.
Hold the mission's inherited-FD advisory integration lock across the final
tip check, merge, and authority publication. Integrate with a normal merge
commit of the immutable verified child-tip SHA, never the mutable child branch
name, so both recorded histories remain
ancestors; never rebase, squash, reset, amend, force-update, or otherwise
rewrite either history. Record `integrated_sha` and the exact child/parent
evidence before advancing both durable states to `integrated`. A verified
repeat is an idempotent no-op.

Immediate child GC consumes only the exact coordinator manifest and integration
records. It proves that the parent contains `integrated_sha`, the integration
contains the recorded child tip, the child worktree is clean and still owns the
exact branch, and local and remote refs still match. It removes only that
worktree and exact local ref. It may delete the matching remote ref only after
a successful remote-state check. Dirty, unmerged, malformed, changed, running,
completed-but-unintegrated, failed, blocked, review, and rework resources are
preserved. A transient or unsafe cleanup failure appends the reason, records
`cleanup_pending`, and retries from durable authority during Phase 0. Missing
already-removed exact resources are accepted only when all remaining ancestry
and authority evidence verifies, so repeated collection is idempotent.
GC and `task-worktree.sh create/reprovision` hold one shared coordinator lifecycle mutation lock
for each mission. The lock uses exact inode ownership,
live-owner refusal, and dead-owner recovery; no separate GC lock domain is
allowed. Every lifecycle lock publication, stale recovery, and release is
serialized through the same short-lived atomic guard directory. A stale guard
has one validated removal winner, and every contender must win a fresh atomic
directory creation before mutating the lifecycle lock; no check-then-remove
path mutation is permitted outside that guard. GC snapshots generation plus
the exact manifest hash and must
revalidate the exact generation and manifest immediately before every
worktree/ref deletion, cleanup-intent phase change, and final state publication.
An epoch mismatch is stale work: stop without publishing state or deleting any
newer-generation resource.
Before the first destructive removal, publish and fsync an exact cleanup intent
and append a durable cleanup-journal entry. After every exact resource is gone,
advance that intent to `resources_collected` before publishing `collected`.
If final state publication fails, retain the intent and reconcile it on retry;
never infer collection merely from missing paths.

### Archive collected child task windows

After durable verified integration and exact child worktree and branch
collection, archive the exact accepted child thread ID recorded in the
authoritative task registry. Thread archival is post-collection hygiene, not
evidence of completion, integration, or collection.
Never archive running, blocked, review, or unresolved-rework tasks.

Failed task windows and every active rework generation also remain visible.

Repeated archival is idempotent. If the authoritative registry already records
that exact thread ID as archived, perform no API call and leave the task state
unchanged. On a successful archive, or when the API authoritatively reports the
exact thread is already archived, record the archival result and timestamp once.
On any other archive API failure, append `task-window archive failure: <reason>`
to the cleanup journal, set the task cleanup state to retriable
`cleanup_pending`, retain the exact accepted thread ID, and retry during Phase 0
reconcile. Never report or record an unverified archive as successful.
The coordinator records `task-window-archive-pending` so Git GC cannot mistake
an archive-only retry for completed resource cleanup. After an authoritative
successful or already-archived result, remove that marker and restore
`collected`; archive failure remains `cleanup_pending` without deleting or
forgetting the exact thread identity.

### Collect an accepted parent mission

Parent GC is a compensating Phase 0 operation and a post-merge acceptance
operation. Before invoking it for a new Hybrid mission, publish the
coordinator-owned `parent-cleanup-manifest.txt` as strict tab-separated rows:
exact canonical parent worktree, exact `orc/<mission>` branch, recorded parent
tip SHA, exact repository, and exact target branch. Publish one-line
`review-resolution=resolved` and `parent-cleanup-state=ready` authorities only
after final Fable review/rework is resolved and merged-tree verification is
recorded. Preserve the final verification evidence as coordinator-owned
`verification.md`, and snapshot the mission-relevant decisions as
coordinator-owned `decisions.md` so later unrelated global decisions cannot
change the archive authority.

Collection requires a clean exact worktree, the exact manifest, no nonterminal
or unresolved child task, and proof that the recorded parent tip is contained
in the target branch. PR metadata is additional evidence only: a merged flag,
PR number, or merge-commit field may corroborate the Git proof but can never
replace target-branch containment of the recorded parent tip. When present,
the exact recorded parent tip must also be an ancestor of the recorded PR merge
commit, and that merge commit must be contained in the target. Missing,
malformed, symlinked, dirty, moved, rewritten, or tip-drifted authority fails
closed.

Every recorded child registry entry must be a canonical, non-symlinked direct
directory under the exact coordinator `tasks/` root with a valid task ID. A
collected child must carry regular, non-symlinked, strict one-line `state`,
`accepted-thread-id`, and `task-window-state` authorities; the accepted thread
identity must be nonempty and valid, and the window state must be exactly
`archived`. Missing, malformed, aliased, or symlinked registry/authority state
blocks parent collection.

Before deletion, GC records and fsyncs the exact cleanup intent and parent
cleanup journal, then preserves the approved three-file authority plus the
approved DAG for Hybrid 0.4, decisions, report, and verification in
`$HUB/archive/<mission>/`. It removes only the manifest-recorded parent
worktree and exact mission-owned `orc/<mission>` local ref. A mission-owned
remote `orc/<mission>` ref is removed only
when its observed tip equals the recorded parent tip, using an exact-tip lease
and a verified absence check. Network, archive, lock, and other transient
failures become durable `cleanup_pending`; retries accept already-removed exact
resources only while all remaining authority and target containment still
verify. The intent binds a durable exact target-ref snapshot. A target may move
forward only when the snapshot tip and recorded parent remain ancestors; rewind
or divergence stops before the next destructive boundary. Archive files use a
write-all loop, file fsync, length/hash read-back, atomic publication, and
directory fsync before cleanup proceeds. After collection, append the terminal cleanup record to the archived
cleanup journal and publish `parent-cleanup-state=collected`.

If the shared lifecycle mutation lock is held by a live owner, do not wait on
or bypass it, and never replace the owner-controlled cleanup state. Outside
that unavailable lock, snapshot the exact completed mission manifest device,
inode, size, and SHA-256 plus the current state bytes, hash, device, and inode.
Publish and fsync only the
canonical no-clobber `parent-cleanup-pending-request.json`, binding those
observations and the retry reason; preserve any existing request rather than
overwriting it. After the owner releases the lock, locked reconciliation
strictly validates and journals the request. It may publish `cleanup_pending`
only when both observed manifest and state epochs are still exact. A stale
manifest marker is removed without changing state or resources and requires a
fresh reconciliation; a newer state is preserved. Normal cleanup continues
only from the resulting current authority.

## Phase 4 — Event-driven wake handling

Read state when the tracked process exits:

- `planned`: enter Phase 3g.
- `executed`: all approved child tasks have been durably completed and
  integrated. First verify `approved.sha256`, the control manifest, and every
  approved artifact. Generate one coordinator-owned full diff per worktree at
  the `REVIEW_DIFFS` paths embedded in Fable's brief. Do not run test commands
  here; write-producing tests belong to the Codex executor. Then, without user
  involvement, write `running` and resume the same Fable session for review:

  ```text
  $PLUGIN_DIR/scripts/spawn-worker.sh --mission-dir <dir> \
    --control-dir $HUB/control/<mission-slug> \
    --worktree <primary> [...] --stage review \
    --resume "The executor finished. Read report.md and all branch diffs, then perform Stage 2 REVIEW per brief.md."
  ```

- `rework`: the reviewer recorded `F<n>` findings. Append a rework timestamp
  and map each finding to the task that owns its files/contracts. On the 3rd rework,
  stop and escalate because the loop is not converging. For an owned child task,
  first require its prior generation to have verified integration, exact
  worktree/branch collection, and a recorded archived task window. Unarchive
  the exact accepted child thread and verify that it is readable before any
  workspace action. If unarchive fails, record `task-window archive failure`,
  set retriable `cleanup_pending`, and do not reprovision or resume. After a
  verified unarchive, re-provision the task's exact manifest-recorded worktree
  path and branch from the updated parent tip, using the same sandbox root.
  Invoke `$PLUGIN_DIR/scripts/task-worktree.sh reprovision` with the exact
  retained control directory, task directory, mission/task identities, repo,
  parent worktree, worktree path, and `--expected-generation <current>`. The
  operation must hold the existing coordinator mutation lock; require terminal
  `integrated`/`collected` authority, an absent old worktree and local branch,
  the exact accepted thread recorded as unarchived, an updated parent tip, and
  unchanged worktree/branch/repo/sandbox authority. It atomically publishes
  matching coordinator and worker manifests, advances generation by exactly
  one, records the new base, and returns both states to `ready`. Ordinary
  `create` never overwrites retained task ownership. If new-authority batch
  publication fails, attempt an exact guarded restore. When that restore is
  incomplete, preserve reprovision-intent, staging, and backups together with
  the exact new worktree/ref; never discard recovery evidence. A retry under
  the same lifecycle lock validates the intent, thread identity, paths, branch,
  new base, and clean worktree, then reconciles every coordinator and worker
  authority file to the one recorded next generation before removing recovery
  artifacts. Before publishing the intent or replacing authority, explicitly
  fsync intent, stage, and backup contents plus their containing directories.
  If execution stops after intent removal but before success returns, an exact
  retry may recognize an already-converged reprovision epoch only when the
  requested generation is exactly N, both authority copies are exactly N+1 and
  `ready`, manifest/base/thread/sandbox/worktree/ref all match, and the worktree
  is clean. This recognition additionally requires a regular, non-symlink,
  fsynced reprovision completion receipt published before intent removal. The
  receipt binds mission/task, old/new generation and base, canonical parent,
  repo, worktree and task paths, branch and exact tips, accepted thread ID,
  sandbox authority, strict one-row manifests and one-line scalar authorities,
  plus exact coordinator and worker content hashes. Missing, malformed,
  symlinked, stale, or hash-mismatched receipts fail closed. Return idempotent
  success without rewriting that epoch only after validating the receipt.
  A later exact operation may atomically supersede the receipt only while
  holding the shared lifecycle lock; a stale receipt never authorizes a newer epoch.
  Any partial or unrelated pre-existing resource remains a hard failure, and
  ordinary `create` never enters this recognition path.
  Re-render its task brief, write the exact owned findings to a bounded task-local
  rework prompt file, and record the new generation and base SHA in the
  authoritative task registry. Only after those records are durable, resume
  the same accepted child thread with the exact findings it owns through
  `$PLUGIN_DIR/scripts/codex-task-client.py resume`, passing its accepted thread
  ID, exact reprovisioned worktree, task state directory, approved model/effort,
  and rework prompt file. Never resume
  against a collected or missing worktree, create a new child, or let one child
  edit another task's files. After all affected tasks return durable completed
  outcomes and their commits are reintegrated, resume the same Fable session
  with `--stage review` for re-review. Rearchive only after verified
  reintegration and exact worktree and branch collection by applying the
  archival protocol above to the same accepted thread ID. If no task registry
  or task identity exists, use the explicit legacy single-executor fallback:
  resume the recorded `codex_thread_id` through `spawn-worker.sh --stage exec`
  in its existing mission worktree.
  In short: unarchive the exact accepted child thread before any rework
  reprovision or resume. Rearchive only after verified reintegration and exact
  worktree and branch collection, always using that same accepted thread ID.
- `blocked`: mediate in Phase 5 and resume whichever backend is named by the
  last `stage:` line.
- `review`: verify approved hashes again, then accept in Phase 6.
- `failed`: report once; do not accept.
- Exit 75 with `QUOTA_LIMIT`: schedule a delayed retry of the exact same stage;
  do not count it as a crash.
- Process exited while state remains `running`: inspect stage-specific output,
  stderr, branches, and artifacts. Resume the recorded backend with a salvage
  instruction. Only if resume itself fails may you append a logged respawn
  addendum and start a fresh session. Two crashes enter Phase 6f.

Whenever a compound command launches a worker, the worker must be its last
foreground command; detaching it loses the exit wake.

## Phase 5 — Mediate BLOCKED

Use `orchestrator:orchestrator-mediation`. Answer from design, plan, decisions,
or code first; decide reversible implementation details; escalate only scope,
user-visible behavior, cost, or data. Write `ANSWER-<n>.md`, append the ruling to
DECISIONS.md, write `running`, then inspect the last `stage:`:

- brainstorm/plan/review: resume Fable without `--stage exec` (use the relevant
  `--stage plan` or `--stage review` label).
- exec: when the BLOCKED file has a task identity and the authoritative task
  registry exists, resume that task's accepted Codex child thread. Never send
  the answer to a different child or create a replacement solely to mediate a
  decision. Write the answer to a bounded task-local resume prompt and invoke
  `$PLUGIN_DIR/scripts/codex-task-client.py resume` with the exact accepted ID,
  worktree, task directory, approved model/effort, and prompt file. If no task
  registry or task identity exists, use the explicit
  legacy single-executor fallback: resume the recorded `codex_thread_id`
  through `spawn-worker.sh --stage exec` in its existing mission worktree.

Never leave a material blocker silently waiting. Notify the user once with the
impact, attempts, exact decision needed, and safe default.

## Phase 6 — Light acceptance and merge

1. Require design.md, plan.md, plan-review.html, brokered commits, and a filled
   report with real `## Code review` and `## Verification` evidence. Missing
   worker-owned evidence returns to the backend that owns it.
2. Verify every branch/base/diff stays inside declared scope and excludes the
   planted `.claude/settings.local.json`. Code corrections always return to
   Codex.
3. For each repo in dependency order, require the user's live checkout to be
   clean and on its default branch. Never switch or clean it for them. Before
   merging, resume the affected Codex child thread for any task-scoped
   verification that may write caches, snapshots, coverage, or generated
   artifacts. The coordinator may run only a test command explicitly attested
   read-only and externally isolated; otherwise rely on the children's fresh
   durable evidence plus Fable review.
   Merge `--no-ff --no-commit`, commit on a verified pass, or abort and resume
   Codex with the exact failure. Two failed acceptance cycles enter Phase 6f.
4. After the merge succeeds, record the completed mission's final parent tip
   and target branch in the exact coordinator parent-cleanup manifest. The
   target branch is containment authority only: never delete or edit it during
   cleanup. Write `review-resolution=resolved`, snapshot fresh merged-tree
   evidence to `verification.md` plus mission-relevant rulings to `decisions.md`,
   reconcile every child Git resource and task
   window, then run `$PLUGIN_DIR/scripts/orchestrator-gc.sh --hub $HUB --clean`.
   The collector archives the required artifacts before removing the planted
   `.claude/settings.local.json` (and `.claude/` if it is then empty), exact
   manifest-recorded parent worktrees, exact mission-owned local `orc/*` refs,
   and the exact matching mission-owned `origin/orc/*` ref for each manifest
   row. A cleanup refusal leaves durable `cleanup_pending`
   and blocks final archival
   completion until Phase 0 resolves it. Never delete or edit the repository's
   shared `.claude/settings.json`, and never collect running, planned, review,
   blocked, failed, nonterminal-child, or unresolved-rework missions.
5. Report shipped changes, decisions, tests, and report follow-ups. Append one
   durable memory entry exactly once.
6. Set state/phase accepted, archive the mission directory, regenerate the
   board, and release already-authorized pending missions.

## Phase 6f — Preserve failure

Enter after two crashes, two failed acceptance cycles, three non-converging
reworks, or explicit user cancellation. Stop a live worker before writing
`failed`. Preserve worktrees, branches, artifacts, and last errors for salvage;
a failed mission does not block another repo owner.

## Codex continuation boundary

Codex continuation uses only supported lifecycle boundaries: the plugin's
`hooks/hooks.json` runs `hooks/codex-continuation.sh` at `PreCompact` and at
`SessionStart` with `source=compact`.
The exact Codex context percentage is unavailable; never claim or emulate the Claude coordinator's separate threshold.
The adapter does not parse `transcript_path` because its format is not stable.
The binding helper supports Python 3.9 or newer and avoids syntax introduced
after Python 3.9.

Before recording a continuation request, write every pending mission, task, registry, decision, BLOCKED, report, and coordinator state update durably.
Publish a strict one-line coordinator session authority under
`$HUB/control/coordinators/` for each exact coordinator task that may own this
boundary. A session is not a coordinator merely because it is not an accepted
child. Only an exact authorized session with at least one eligible nonterminal
mission may publish, emit, record, reject, or accept a continuation. Completed,
accepted, collected, failed, unrelated, and child sessions emit nothing.

The adapter writes an immutable request-scoped carryover under
`$HUB/control/continuations/carryovers/`; `$HUB/CARRYOVER.md` is only a latest
human-readable pointer and never acceptance authority. The canonical request
binds the exact mission, task generation, and durable state snapshot. It also
binds the physical hub and mission/task paths; exact coordinator authority;
every mission/task state, generation, and accepted-child
identity with bytes, hashes, device, inode, size, and path; plus the immutable
carryover bytes and epoch. Its request ID is the SHA-256 of the entire canonical
binding. Publish both the strict one-line request and its inode/content binding
receipt with fsync and no-clobber semantics. Set `umask 077` before store work:
continuation directories use mode `0700`, and request, carryover, health,
receipt, provenance, promotion, and coordinator-authority files use mode `0600`.
Every `SessionStart`, attempt, rejection, and acceptance entry must
recompute the digest, re-derive the current hub and carryover authority, and
reject any mutation, symlink, escape, malformed JSON, or state drift.

Automatic and manual triggers for the same exact coordinator and hub-state
epoch are equivalent and converge to one request ID. Event and trigger values
never enter request identity or canonical carryover bytes; preserve them as
request-scoped no-clobber provenance receipts. Equivalent concurrent calls
reuse the request while preserving each distinct provenance.

Preflight every physical hub/control/mission/task/store/carryover component
before mutation; never `mkdir -p` through an unverified ancestor. Store creation
uses dirfd/openat-style no-follow traversal. One bounded in-memory coordinator
snapshot supplies the state hash, carryover, binding, request, and receipt; do
not independently reread the hub between those outputs. If a matching
`PreCompact` cannot prove carryover, request, binding-receipt, and directory
durability, return the supported blocking response with `continue:false` and do
not allow compaction. Repeated delivery for the same exact source and state
reuses the immutable request. Never restart, replace, resume, or duplicate active child execution during carryover.

After compact `SessionStart` injects the request ID, append any relevant
in-context-only knowledge to durable state before task creation, then revalidate
the request's exact state and carryover hashes. Render
`templates/continuation.md` and create one fresh project-local Codex task, not a
fork. Record its provisional ID with the adapter. Apply the full Codex Loop
Engineering continuation health check: exact list/read visibility, title, first
turn, normal active/completed status, startup evidence, and requested settings
evidence.
Pass the request's exact coordinator session ID on every attempt/reject/accept
adapter call. One crash-recoverable, no-symlink, hard-link protocol lock covers
request and attempt terminal transitions so accept and reject cannot both win.
Stale-lock recovery first returns one fd-read canonical epoch containing exact
dev/inode/size/content hash/token plus owner liveness. Guard hard-link creation,
guard/current same-fd reread, exact epoch comparison, and relative unlink all
run in the verified parent dirfd. If the path changes from dead A to any B,
recovery removes only its exact guard, preserves B, and retries or fails closed;
no transition may publish until this lock acquisition succeeds.
The accept operation reads bounded health evidence once, validates and hashes
those same bytes, publishes an immutable request-scoped copy, and binds the
accepted receipt to that copy and the request binding receipt. Only then publish
the accepted continuation receipt. A failed or unreadable provisional task gets a durable
rejection receipt and at most one replacement. A second failure is BLOCKED;
exactly one task can be accepted for the request.

Immediately after health acceptance, run the explicit promotion operation:

```text
hooks/codex-continuation.sh --promote-coordinator \
  --hub "$HUB" --request-id "<request-id>" \
  --coordinator-session-id "<source-coordinator-id>" \
  --thread-id "<exact-accepted-thread-id>"
```

Promotion uses the same protocol lock, verifies the accepted receipt and exact
request generation, and publishes a private staged authority plus exact intent.
The staged authority is inactive. A single canonical regular fsynced atomic
no-clobber `<request-id>.promotion-commit.json` marker binds the old authority
inode/bytes/hash, staged new authority, accepted receipt/thread, request binding,
and mission/task generation/state. Classification derives ownership only from
that committed epoch: old is the sole coordinator before commit and new is the
sole coordinator after commit. New-authority, legacy supersession, and promotion
summary files are post-commit retriable evidence and never control eligibility.
Crash, TERM, or ordinary retry at every boundary converges idempotently. The
accepted task is not a coordinator until the commit marker is durable; never
infer promotion from a filename convention.

Every authority read opens the verified absolute parent component-by-component
with dirfd plus `O_DIRECTORY|O_NOFOLLOW`, then opens the leaf relative to that
dirfd with `O_NOFOLLOW`, checks the exact dev/inode/mode/size epoch, performs a
bounded read on that same file descriptor, and rechecks the epoch. Never use a
path-based `open()` after `lstat()` for request, state, coordinator, receipt,
health, carryover, or lock authority.

An exact accepted receipt is terminal. `PreCompact`, compact `SessionStart`, and
manual retries for that request are silent terminal no-ops; they never inject or
create another continuation. Malformed terminal receipts fail closed rather
than being treated as absent.
An exhausted second attempt is also terminal. Record, accept, and exact-reason
reject replays are artifact-free successes; a conflicting reject reason fails
closed and preserves the original receipt.

When automatic lifecycle delivery or task creation is unavailable, use the
same manual coordinator boundary: finish and fsync the durable coordinator
state, invoke `hooks/codex-continuation.sh --manual --hub "$HUB" --session-id
"<current-task-id>"`, then follow the identical provisional-attempt, health
check, and acceptance protocol, passing `--coordinator-session-id
"<current-task-id>"` for each transition. Manual continuation does not invent a context
percentage and does not weaken duplicate or child-execution suppression.

## Board and carryover

Regenerate board.html from `$PLUGIN_DIR/templates/board.html` on every state
transition. Its valid states include pending, running, planned, executed,
rework, blocked, review, accepted, and failed. At material context pressure,
write CARRYOVER.md and ensure disk state is current. A carryover or board entry
never substitutes for user notification of a blocker.

## Non-negotiables

- Fable owns brainstorm, plan, review, and re-review; it never edits code.
- GPT-5.6-Sol owns every implementation and rework change.
- Plan and review reuse one Claude session. Each task reuses its own Codex child
  thread for rework; no child owns another task.
- Never edit or inspect a running stage between process-exit wakes.
- Mission workers never ask the user directly; they use BLOCKED files.
- Only the coordinator writes shared MEMORY.md, DECISIONS.md, and board.html.
- Decision and memory numbers are host-prefixed: `D-<HOST>-<seq>` / `M-<HOST>-<seq>`. `<HOST>` is a short stable tag for THIS machine (`Linhans-MacBook-Pro.local` → `LMBP`, `LY_GAMING` → `LYG`; reuse the tag the hub already carries for this machine rather than minting a variant), and `<seq>` counts only entries bearing this host's tag, so concurrent hosts never collide. Never mint, renumber, or reuse another host's tag — a remote-authored entry is read-only, and its number is how other missions cite it. Cite bare legacy `D-<seq>`/`M-<seq>` entries by their existing number and never renumber them opportunistically.
- Never bypass the OS sandbox, hook guard, pipeline gate, or commit broker.
- Every Hybrid launch passes `--control-dir $HUB/control/<mission-slug>`; the
  control manifest and frozen approved contract are never worker writable.
- Never merge without a clean independent Fable verdict and fresh merged-tree
  verification.
