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

Render the shared `templates/brief-codex.md` for either backend. The planning
session writes only mission artifacts; product implementation and rework remain
owned by GPT-5.6-Sol high child tasks.

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
read-only on product worktrees and may write only the mission artifacts.

## codex-ultra

Require app-native task tools. Create one visible planning/review task with its
own context by calling `create_thread` under the coordinator saved project,
using `environment=worktree`, `model=gpt-5.6-sol`, and `thinking=ultra`.
Do not fork. Give it a deterministic title:

`ORC <mission> · planning/review · GPT-5.6-Sol Ultra`

Use this deterministic bootstrap prompt with a coordinator-generated token:

```text
Planning bootstrap only. Do not modify product files, Git, or create tasks.
Read the rendered planning brief and backend authority. Write exactly
<planning-root-token> plus one newline to
<mission-dir>/planning-writable-root-receipt. Report the exact cwd, HEAD,
clean status, and receipt; then stop.
```

Before each planning or review turn, record every product worktree's exact tip
and clean status as the stage-entry baseline. The bootstrap turn is
product-read-only. It verifies the rendered planning brief, mission/control
paths, worktree table, backend authority, and exact mission-artifact writable
root by writing a one-line `planning-writable-root-receipt`. Treat the returned
ID as provisional until native wait/list/read evidence confirms the exact title,
parent source, first turn, idle/normal status, model, effort, project target,
native planning worktree, and receipt.

Keep mission state `pending` during bootstrap. After health acceptance, publish
the exact formal ID in coordinator
`planning-thread-id` and a private canonical
`planning-thread-health.json` with exactly these keys:

```text
created visible title_verified first_turn_exists startup_evidence
settings_recorded writable_root_verified status thread_id model effort
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

Then use `send_message_to_thread` with
the rendered brief. Wait for terminal wake and consume mission artifacts rather
than replaying the planning transcript into the coordinator. Before accepting
the stage outcome, verify every product worktree remains clean and at its
stage-entry tip; any drift rejects the outcome and becomes BLOCKED.

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
