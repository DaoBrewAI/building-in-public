# Planning and review backends

Read this file before launching or resuming brainstorm, design, plan, review, or
re-review. The selected backend owns all five stages for the mission.

## Durable selection

The only valid values are `fable-opus` and `codex-ultra`. Require matching
one-line `planning-backend` files in the mission and coordinator control
directories before launching either backend. Treat a mismatch or later backend
change as BLOCKED. Never switch a selected backend without explicit user
direction.

Render `{{PLANNING_BACKEND_SPEC}}` as:

- `plan/review claude-fable-5 · effort high (guarded) · Opus-5 quota fallback`
  for `fable-opus`;
- `plan/review gpt-5.6-sol · effort ultra · visible project-local task` for
  `codex-ultra`.

Render the shared `templates/brief-codex.md` for either backend. Product
implementation and rework remain owned by GPT-5.6-Sol high child tasks. The
selected backend determines the only writable output route described below.

## fable-opus

Use the existing `scripts/spawn-worker.sh` lifecycle. Fable-5 high owns
brainstorm, design, plan, review, and re-review. Reuse the same accepted Claude
session for clarification, founder corrections, review, and re-review. On a
fresh plan, leave mission state `pending`; the launcher publishes and fsyncs
`session.txt` plus `control/planning-session-id`, then writes `running` before
invoking Claude. A pre-transition failure therefore remains recoverable. On a
real Fable quota wall, retry that stage once with Opus-5 high and record the
no-clobber `control/quota-fallback-<stage>.json` receipt with exactly
`from=claude-fable-5`, `to=claude-opus-5`, `stage=plan|review`, and the
coordinator-owned `session_id`. The launcher atomically publishes that original
Fable identity in `control/planning-session-id`; every resume must match it.
Launch the resume with `ORC_PLAN_MODEL=claude-opus-5` and
`--quota-fallback`. The exact Opus session may resume with that receipt; a
second fresh fallback for the same stage is forbidden. The launcher accepts no
other planning model. No other fallback is allowed.

This route uses the external-planning policy in the entry skill. Fable/Opus is
read-only on product worktrees. Fable/Opus writes mission artifacts directly;
the existing launcher and mission-state protocol are unchanged.

## codex-ultra

Require app-native task tools. Create one visible planning/review task with its
own context by calling `create_thread` under the coordinator saved project,
using `environment=worktree`, `model=gpt-5.6-sol`, and `thinking=ultra`.
Do not fork. Give it a deterministic title:

`ORC <mission> · planning/review · GPT-5.6-Sol Ultra`

Use this deterministic repository-no-write bootstrap prompt:

```text
Planning bootstrap only. Do not modify product files, Git, or create tasks.
Read the rendered planning brief and backend authority. Report the exact cwd,
HEAD, detached/branch state, and clean status; then stop without writing.
```

Before each planning or review turn, record every product worktree's exact tip
and clean status as the stage-entry baseline. The bootstrap turn is
product-read-only. It verifies the rendered planning brief, mission/control
paths, worktree table, backend authority, and native planning worktree. Treat
the returned ID as provisional until native wait/list/read evidence confirms
the exact title, first turn, idle/normal status, model, effort, requested
project target (observed non-null and exact), native planning worktree, exact tip, and clean status. The
coordinator source is frozen create-request provenance: a missing
`sourceThreadId` projection is unobservable, and only an explicit non-null
mismatch is a health failure. Follow
the Codex Loop Engineering native health sequence: replacement is limited to a
genuine native launch or identity-health failure. Permission denial never
triggers planning-task replacement. Planning, review, BLOCKED, importer, and
broker outcomes are task outcomes and never replacement signals.

Keep mission state `pending` during bootstrap. After health acceptance, publish
the exact formal ID in coordinator
`planning-thread-id` and a private canonical
`planning-thread-health.json` with exactly these keys:

```text
created visible title_verified first_turn_exists startup_evidence
settings_recorded worktree_verified status thread_id model effort
project_id cwd
```

All seven boolean checks are `true`; status is `inProgress`, `completed`, or
`idle`; thread/model/effort equal the accepted request; project ID records the
requested saved-project target; cwd is the native planning worktree. Treat
model/effort as recorded requested settings when native read does not expose
them, and never claim they were independently observed.

For `codex-ultra`, mission `session.txt` contains exactly one each of
`backend: codex-native`, `model: gpt-5.6-sol`, `effort: ultra`,
`thread_id: <formal-id>`, and `stage: plan|review`. Atomically replace only
the stage line on the review transition.

Before **every** plan, clarification-resume, founder-correction, review, or
re-review message, the coordinator runs `scripts/planning-output.py begin` with
the exact mission/control directories, native planning worktree, stage-entry
tip, stage, and explicit current `--expected-state`. Valid plan entry states are
`pending`, `running`, `blocked`, or `planned`; valid review entry states are
`running`, `executed`, `blocked`, `rework`, or `review`. `begin` verifies that
state instead of merely sampling it and atomically publishes one active
coordinator-owned stage nonce and exact expected mission state. Use the returned
nonce in that turn's rendered brief/message. Never send the turn until this
authority is durable, and never open a second stage authority while one remains
active.

Then use `send_message_to_thread` with the rendered brief. For `codex-ultra`,
the child writes only `.orchestrator-planning-output` inside its native planning
worktree. It never writes mission/control paths. The staging directory contains
one canonical `manifest.json` plus exactly the artifacts selected by this stage:

- `plan/planned`: `design.md`, `plan.md`, `plan-review.html`, `task-dag.json`;
- `review/review|rework`: `report.md`;
- `plan|review/blocked`: exactly the next `BLOCKED-<n>.md`.

`manifest.json` has exactly `protocol_version=1`, `stage`, `kind`,
`accepted_thread_id`, physical `worktree`, stage-entry `tip`, and the ordered
`artifacts` list, plus the exact `stage_nonce` returned by `begin`. No extra
file, directory, or symlink is permitted.

Wait for terminal wake, then the coordinator runs
`scripts/planning-output.py import` with the exact mission/control directories,
native planning worktree, stage-entry tip, and stage. The importer verifies the
exact worktree and tip, zero tracked product drift, and no untracked files
outside staging; validates the exact stage schema and accepted thread; atomically
imports the plan, review, or BLOCKED artifacts and derived mission state; then
records a durable content-bound receipt and removes staging. It rejects any
nonce or expected-state mismatch, so stale or delayed output from an earlier
plan, clarification, review, or re-review round cannot satisfy the current
turn. Import failure before publication preserves staging and prior mission
artifacts. If publication succeeded but staging cleanup was interrupted, retry
the same import after a post-publication cleanup interruption; the intent,
receipt, and consumed-staging tombstone make that retry idempotent. Do not call
`begin` again for recovery.
Before acceptance, verify every product worktree remains clean and at its
stage-entry tip.
Do not replay the planning transcript into the coordinator or accept chat text
as the durable outcome.

Reuse the same accepted thread for clarification, founder corrections, review,
and re-review. On review, send only frozen design/plan paths, bounded diff
artifacts, task reports, and the review instruction. This planning/review task
must never implement or rework product code, create implementation children, or
commit. It is independent from every implementation owner even though the
selected model is also GPT-5.6-Sol.

Retain the accepted planning thread through every review round. Archive the
planning/review task only after the final verdict is durably accepted; its
native planning worktree is never part of implementation integration or child
GC authority.

When founder corrections change design or plan, regenerate `plan-review.html`;
the coordinator redeploys the same `/plan` route before asking for `go` again.
The planning/review task never publishes or manages the Site.

If native creation or messaging is unavailable, write
`native-planning-task-api-unavailable` and stop before planning. Do not use
App Server, hidden `codex exec`, the coordinator context, Fable, or Opus as a
silent fallback.

## Shared stage contract

- Brainstorm clarification still uses one durable question per turn.
- Founder `go` still freezes the same design, plan, brief, and task DAG.
- Review still reads frozen authority and coordinator-generated bounded diffs.
- Findings still return to their exact implementation owners.
- Three nonconverging review rounds still stop the mission.
