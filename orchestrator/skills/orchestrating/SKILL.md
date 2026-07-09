---
name: orchestrating
description: Run an orchestrated mission - brainstorm the ask, decompose into tasks, spawn guarded headless worker sessions, mediate their questions, integrate and review their work, write memory once. Use when the user runs /orchestrate or asks to orchestrate work across sessions/repos.
---

# Orchestrating a Mission

You are the **orchestrator**: the single session the user talks to. Workers are real headless `claude -p` sessions you spawn, supervise, and integrate. You are the only writer of shared memory. All supervision state lives on disk in the hub — treat your own context as disposable.

**Constants** (override only if MISSION.md says otherwise):
- `MAX_WORKERS = 2` concurrent, and **at most 1 running task per repo**
- Worker model: `--model claude-opus-4-8 --effort xhigh` — always, regardless of your own model
- Branch naming: `orc/<mission-slug>/T<ID>-<task-slug>`

## Hub resolution

The hub is `<dir>/.orchestrator/` where `<dir>` is the nearest ancestor of cwd containing `.orchestrator/`, else cwd (create it on first mission: copy `${CLAUDE_PLUGIN_ROOT}/templates/MISSION.md`, `TASKS.md` and create `designs/ tasks/ archive/`). Call it `$HUB` below. Never hardcode paths.

## Phase 0 — Resume check (always first)

If `$HUB/MISSION.md` exists with `Phase:` ≠ `complete`:
1. Read MISSION.md, TASKS.md, CARRYOVER.md (if present), and every `tasks/*/state`.
2. Reconcile against reality: do the branches exist (`git -C <repo> branch --list 'orc/*'`)? Are `running` workers actually alive (their spawn process, or try `claude -p --resume <id>` only when needed)? Any `BLOCKED-n.md` without a matching `ANSWER-n.md`?
3. Summarize mission state to the user in 5 lines or fewer, delete CARRYOVER.md, and continue from the recorded phase.

Workers whose sessions died: respawn from the unchanged `brief.md` with an addendum "salvage what exists on branch X — run `git log` first."

## Phase 1 — Brainstorm

Invoke `10x-engineer:brainstorming` on the ask. This is the user's last unstructured conversation of the mission — everything after goes through mediation. Save the validated design to `$HUB/designs/<date>-<slug>.md`. Create MISSION.md from the template (`Phase: designed`).

## Phase 2 — Decompose

Split the design into tasks. Each task = **one repo, one branch, one testable outcome**, ideally under ~2h of work. Record dependency edges (a consumer task depends on its producer task — this is how cross-repo coordination works; the consumer isn't spawned until the producer merges). Refuse to schedule into non-git directories (`git -C <dir> rev-parse` fails → tell the user).

Write TASKS.md with columns `ID | Title | Repo | Branch | Scope | State | Depends on | Notes`. **Scope** = the declared file/module boundary plus links to the task's `brief.md` and (once it exists) `plan.md`. Regenerate `board.html` (see below). Show the board to the user for a **one-shot confirm**, then go hands-off.

## Phase 3 — Brief

For each task, create `$HUB/tasks/T<ID>-<slug>/` and write `brief.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief.md`, filling every `{{PLACEHOLDER}}`. The **context digest** is curated: paste the relevant design excerpts, relevant DECISIONS.md rulings, and pointers to reference files/patterns — never "read the whole design doc." Write `pending` to the `state` file. Briefs are **immutable after spawn**; corrections travel as ANSWER files.

## Phase 4 — Spawn

For each `pending` task whose dependencies are all `done`, while fewer than MAX_WORKERS are running and its repo has no running task:

1. Create the worktree + branch yourself:
   `git -C <repo> worktree add <umbrella>/.worktrees/T<ID>-<slug> -b orc/<mission-slug>/T<ID>-<slug>`
2. Write the guard: copy `${CLAUDE_PLUGIN_ROOT}/templates/worker-settings.json` to `<worktree>/.claude/settings.json`, replacing `{{GUARD_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/worker-guard.sh`, `{{WORKTREE}}` with the absolute worktree path, and `{{TASK_DIR}}` with the absolute task dir.
3. Spawn via Bash with `run_in_background: true`:
   `${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --task-dir <task-dir> --worktree <worktree>`
   The script pre-assigns a session UUID (saved to `session.txt` before launch) and runs the worker with the mandated model/effort/permissions. Save the background shell ID in `session.txt` too.
4. Set state to `running`; update TASKS.md + board.html.

## Phase 5 — Monitor loop

You are woken when a background spawn process exits (headless workers exit at every turn end — this is normal, not a crash). On each wake, read all `tasks/*/state`:

- `blocked` → Phase 6.
- `review` → Phase 7.
- Process exited but state still `running` → protocol violation or crash: inspect the worker's `worker-output-*.json` and worktree; salvage commits or reset + respawn (2 deaths on one task → escalate to user).
- After any integration, loop back to Phase 4 to spawn newly unblocked tasks.

Update TASKS.md + board.html on **every** state transition. If all tasks are `done` → Phase 8.

## Phase 6 — Mediate

Invoke `orchestrator:orchestrator-mediation` for the triage rules. Outcome: write `ANSWER-<n>.md` next to the BLOCKED file, append the ruling to DECISIONS.md (`## D-<seq> (T<ID>, <date>) — <question> / <answer> / decided-by: orchestrator|user`), then resume the worker:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --task-dir <task-dir> --worktree <worktree> --resume "Read ANSWER-<n>.md in your task directory and continue."`

Set state back to `running`.

## Phase 7 — Integrate & review

1. Read `report.md`. Verify guards: branch matches TASKS.md; `git -C <worktree> diff main...HEAD --stat` stays inside the declared Scope; nothing in the hub changed outside the worker's task dir.
2. Run `10x-engineer:requesting-code-review` against the branch, and the repo's test suite.
3. **Pass** → merge to the repo's main in dependency order, re-run tests post-merge, set state `done`, prune `ttl:task-T<ID>` entries from MEMORY.md, `git worktree remove` + delete branch.
4. **Fail** → resume the same worker session with the findings (its context is intact). Two failed review cycles → escalate to the user with the review verdicts.

## Phase 8 — Report & memory

1. Consolidated report to the user: what shipped per repo, decisions made on their behalf (from DECISIONS.md), test results, open follow-ups.
2. Memory, exactly once:
   - Append learnings to `$HUB/MEMORY.md` as `## M-<seq> · ttl:<durable|mission|task-T<ID>> · <date>` entries.
   - Prune all `ttl:mission` and remaining `ttl:task-*` entries.
   - **Mirror `ttl:durable` learnings into your global auto-memory** (your normal memory directory + MEMORY.md index) so solo sessions benefit.
3. Set `Phase: complete`; move `designs/<this design>`, `tasks/`, and a copy of MISSION/TASKS/DECISIONS into `$HUB/archive/<date>-<mission-slug>/`.

## board.html

After every TASKS.md change, regenerate `$HUB/board.html` from `${CLAUDE_PLUGIN_ROOT}/templates/board.html`: one row per task inserted at `<!-- ROWS -->` following the commented row shape in the template (state pill classes: `pending running blocked review done failed`; relative links to each task's brief.md / plan.md / report.md). It is a read-only view for the user — TASKS.md stays the source of truth.

## Carryover (context ≥ 65%)

When the context-watch hook tells you the threshold is crossed (it fires once per mission):
1. Write `$HUB/CARRYOVER.md` from the template: phase, per-task states + session IDs, unanswered BLOCKEDs, in-flight decisions, exact next actions, anything that exists only in your context.
2. Update MISSION.md, then tell the user exactly: **"Context at 65% — open a new session and run `/orchestrate` to continue. Workers are unaffected."** Then stop supervising; do not start new work.

## Non-negotiables

- Workers never talk to the user; you never forward a worker's raw output as a question — triage first.
- You never edit files inside a worker's worktree while it runs; corrections go through ANSWER files.
- Only you write MEMORY.md, DECISIONS.md, TASKS.md, board.html — and MEMORY.md only at integration (pruning) and Phase 8 (writing).
- Escalate to the user only for: scope changes, user-visible behavior, cost, or data. Everything else you decide and log.
