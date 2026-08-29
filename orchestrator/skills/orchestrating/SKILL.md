---
name: orchestrating
description: Run native Hybrid Codex missions in which Claude Fable-5 brainstorms, plans, and independently reviews while visible Codex GPT-5.6-Sol child tasks perform every implementation and rework change.
---

# Native Hybrid Orchestrator

Coordinate one durable native `0.4.0` mission pipeline. Fable plans and reviews;
visible Codex tasks implement; the coordinator owns authority, scheduling,
integration, mediation, cleanup, and continuation.

## Fixed ownership

- Fable-5 high owns brainstorm, design, plan, review, and re-review. When Fable
  has a quota wall, automatically retry that stage once with Opus-5 high and
  record `quota-fallback: <date> <stage> fable→opus`.
- GPT-5.6-Sol high owns every implementation, test-producing fix, and rework.
  The coordinator creates and messages each visible project-local Codex task
  with app-native task APIs, then adopts that task's native worktree through
  `scripts/task-worktree.sh`. Never use hidden `codex exec` sessions or App
  Server execution.
- Fable is read-only on worktrees. Codex children write only their declared
  task files and task-state directory. Commits pass through
  `scripts/commit-broker.sh`.
- Branches are `orc/<mission>` and `orc-task/<mission>/<task-id>`. Independent
  missions may share a repository because each has isolated worktrees.

## Progressive-disclosure router

Read only the reference needed for the current stage, completely, before acting:

- Before computing a ready set, creating/resuming a child, consuming an outcome,
  or integrating a task, read [references/task-execution.md](references/task-execution.md).
- Before child/parent collection, task-window archival, rework reprovision, or a
  cleanup retry, read
  [references/cleanup-and-rework.md](references/cleanup-and-rework.md).
- At `PreCompact`, compact `SessionStart`, manual continuation, or coordinator
  promotion, read [references/continuation.md](references/continuation.md).
- When mission state is `blocked`, use `orchestrator:orchestrator-mediation`.

Do not preload all references at startup.

## Required assets

Resolve `PLUGIN_DIR` by moving up two directories from this file. Require:

- `scripts/spawn-worker.sh`, `provision-preflight.sh`, `pipeline-gate.sh`,
  `worker-guard.sh`, and `install-worker-settings.sh`;
- `scripts/validate-task-dag.sh`, `task-worktree.sh`, `integrate-task.sh`,
  `commit-broker.sh`, `orchestrator-gc.sh`, `classify-mission-version.sh`, and
  `codex-task-client.py`;
- `templates/MISSION.md`, `brief-codex.md`, `brief-exec.md`, `task-brief.md`,
  `task-dag.json`, `report.md`, `worker-settings.json`, and `board.html`.

Missing assets are a hard plugin-installation error.

## External planning mode

Invoking Orchestrator authorizes `auto-least-scope` Fable/Opus planning and
review for task-relevant source, build configuration, and tests. Give this
nonblocking notice once, then continue:

`External planning: auto least-scope — Fable/Opus read-only; relevant source/tests only; secrets and customer/personal data excluded. Continuing now.`

Do not ask for confirmation unless the user explicitly selected
`approval-required`. Use `no-external` only when the user explicitly forbids
Fable/Opus; the fixed Hybrid workflow then cannot run.

Always exclude credentials, tokens, OAuth values, personal/customer data,
customer documents/outputs, ignored/private corpora, and unrelated files.
Sanitize and continue. A concrete host/tool denial is authoritative; generic
caution is not. Never reauthorize the same least-scope stage after a new chat,
reauthentication, resume, review transition, or Fable→Opus quota fallback.

## Hub and native authority

`HUB` is the nearest ancestor of cwd containing `.orchestrator/`, or cwd on
first use. Its coordinator state is outside every worker-writable root:

```text
$HUB/.orchestrator/
  missions/<mission>/
  control/<mission>/
  archive/<mission>/
  DECISIONS.md
  MEMORY.md
```

Every mission must have coordinator-owned `pipeline-version` containing exactly
`0.4.0`. Run `scripts/classify-mission-version.sh` before trusting a mission;
anything else is unsupported and preserved without mutation.

## Phase 0 — reconcile

1. Delete `$HUB/.carryover-notified` in a fresh context.
2. Run report-only discovery:

   ```text
   $PLUGIN_DIR/scripts/orchestrator-gc.sh --hub $HUB
   ```

   Never use hub-wide destructive cleanup here. Warnings from unrelated missions
   do not block new scheduling and never require user authorization. Block only
   exact worktree/ref reuse or a real output dependency.
3. For a specifically resumed `cleanup_pending` mission, read the cleanup
   reference and run only:

   ```text
   $PLUGIN_DIR/scripts/orchestrator-gc.sh --hub $HUB --mission <mission> --clean
   ```
4. Read each mission's state, session history, exact worktree manifest, control
   authority, newest unanswered BLOCKED file, and task registry. Treat an
   uncertain process as alive, recheck once, and never double-spawn.
5. Summarize active missions in at most five lines, then route by state.

## Phase 1 — record

Resolve the repository set without making product decisions. Create one unique
date-prefixed mission directory and its matching control directory. Persist the
complete user request in `request.md`, render `MISSION.md`, write `pending`, and
atomically publish coordinator-owned `pipeline-version`=`0.4.0` before exposing
any worker-writable root. If repository scope is materially ambiguous, ask once.

## Phase 2 — provision

1. Require every repository to pass `git rev-parse`. Preserve dirty live
   checkouts; all mission work happens in isolated worktrees.
2. Queue only for exact worktree/ref reuse or a concrete output dependency such
   as overlapping files/contracts or migration order. Otherwise run missions in
   parallel.
3. Create `<umbrella>/.worktrees/<mission>/<repo>` on `orc/<mission>`. Record
   exact tab-separated `worktree branch base-sha repo` rows in the coordinator
   manifest, then copy them byte-for-byte to the mission.
4. Preserve shared `.claude/settings.json`. Install mission hooks only in the
   primary worktree's `.claude/settings.local.json` with
   `install-worker-settings.sh`; freeze and verify its hash.
5. Render `brief.md` from `brief-codex.md`, `brief-exec.md` from
   `brief-exec.md`, and `report.md`. Fill every placeholder with a curated
   digest, exact paths, tests, and accepted baseline failures.
6. Run `provision-preflight.sh` outside the worker sandbox. Do not launch over
   an unadjudicated red baseline.

## Phase 3 — Fable brainstorm and plan

Write `running`, then launch `spawn-worker.sh` with the mission/control paths and
all worktrees. The same Fable session invokes `10x-engineer:brainstorming` and
may return `blocked` with `kind: brainstorm-clarification`. Mediate that single
question and resume the same session. It then writes `design.md`, `plan.md`,
`plan-review.html`, and `task-dag.json`, sets `planned`, and exits.

Do not poll or inspect a healthy running stage. The process exit is the wake.

## Founder go gate

`planned` is the only planned human pause. Require and show `design.md`,
`plan.md`, and `plan-review.html`. Ask for explicit **go**. Corrections resume
the same Fable session so design changes before plan regeneration.

On go:

1. validate and freeze the DAG with `validate-task-dag.sh --freeze`;
2. snapshot `approved-design.md`, `approved-plan.md`, `brief-exec.md`, and
   `approved-task-dag.json` into control;
3. publish their four-entry SHA-256 manifest;
4. write `running`; and
5. read `task-execution.md`, compute the ready set, and create visible Codex
   child tasks.

## State router

- `running`: reconcile the recorded Fable process or accepted child tasks; do
  not duplicate healthy work.
- `planned`: enter the founder go gate.
- `executed`: verify frozen authority, generate coordinator-owned review diffs,
  read `cleanup-and-rework.md`, batch-collect every integrated child, archive
  every child window, then write `running` and resume the same Fable session
  with `--stage review`. Do not collect an individual child earlier.
- `rework`: read `cleanup-and-rework.md`; route every finding to its owning
  child task and reuse that task's accepted thread.
- `blocked`: use mediation, persist `ANSWER-<n>.md` and the decision, then resume
  the exact Fable stage or accepted Codex task that blocked.
- `review`: enter acceptance.
- `accepted` or `cleanup_pending`: finish mission-scoped cleanup and archival.
- `failed`: report once and preserve all resources.
- Fable exit 75: schedule one retry of the same stage at the reset time; it is
  not a crash. Two real crashes preserve failure state and resources.

## BLOCKED mediation

Answer from approved artifacts, durable user decisions, or code first. Decide
reversible implementation details. Escalate only scope, user-visible behavior,
cost, or data/privacy. Persist the answer and resume the same owner; never create
a replacement task merely to mediate a question.

## Acceptance

1. Require real design/plan, brokered commits, Fable verdict, task reports, and
   raw verification evidence. Missing evidence returns to its owner.
2. Verify every diff stays inside declared files/contracts and excludes planted
   settings. Code corrections always return to Codex.
3. Require each live checkout clean and on its default branch. Merge verified
   immutable task/parent tips without rewriting history. Run final merged-tree
   verification before claiming acceptance.
4. Publish exact parent cleanup authority, resolved review, decisions, and
   verification. Write mission state/phase `accepted`, then read the cleanup
   reference and run mission-scoped GC. Never run hub-wide destructive cleanup.
5. Archive the mission directory only after `parent-cleanup-state=collected`.
   Otherwise preserve it for exact retry. Regenerate `board.html` on every state
   transition.
6. Report changes, decisions, tests, and follow-ups; append durable memory once.

## Continuation

The Codex hook handles `PreCompact` and compact `SessionStart`. Before any
continuation operation, read `references/continuation.md` and durably flush all
mission/task decisions, registries, states, reports, and carryover. Never invent
a context percentage or duplicate active child work.

## Non-negotiables

- Only the coordinator writes shared `DECISIONS.md`, `MEMORY.md`, and board.
- Decision/memory IDs are host-prefixed and never renumbered.
- Never bypass sandbox, guard, pipeline gate, lifecycle locks, or commit broker.
- Never read or steer a healthy child mid-run; consume durable outcomes at wake.
- Never integrate completion without exact tip, ancestry, clean-worktree, and
  verification evidence.
- Never delete target/default branches or resources outside exact authority.
