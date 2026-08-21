# Orchestrator Mission Task DAG + Two-Level GC Implementation Plan

## Goal

Upgrade Orchestrator so one approved mission may execute independent plan tasks in fresh Codex task windows without consuming the coordinator's context, then integrate and collect those child resources safely. Preserve Fable planning/review ownership, founder go, frozen approved artifacts, sandboxing, BLOCKED mediation, commit broker, final verification, and merge gates.

## Required architecture

```text
Fable design + approved plan + task DAG
                  |
       coordinator computes ready set
          /           |           \
 child task A    child task B    child task C
 own thread       own thread      own thread
 own worktree     own worktree    own worktree
          \           |           /
          verified integration gate
                  |
          parent orc/<mission>
                  |
         final Fable review/rework
                  |
         verified merge into target
```

Branches:

- Parent: `orc/<mission>`
- Child: `orc-task/<mission>/<task-id>`
- Never use `orc/<mission>/<task-id>` because it conflicts with the Git ref for `orc/<mission>`.

Scheduling depth is bounded to `coordinator -> mission -> child task`. Child threads never create grandchildren. The coordinator alone creates threads, computes dependencies, integrates commits, and performs cleanup.

## Dependency plan

| Task | Wave | Depends on | Primary files |
| --- | --- | --- | --- |
| 1. Baseline and Codex hook capability audit | A | -- | plugin manifests, existing tests, local runtime/schema evidence |
| 2. Approved task-DAG contract and validator | B | 1 | `templates/brief-codex.md`, DAG template, validator, tests |
| 3. Child branch/worktree lifecycle | B | 1 | new lifecycle script and tests |
| 4. Coordinator child-thread protocol | B | 1 | `skills/orchestrating/SKILL.md`, task brief/state contracts, static tests |
| 5. Child integration and immediate GC | C | 2, 3, 4 | integration script, `orchestrator-gc.sh`, tests |
| 6. Parent merge detection and reconcile GC | D | 5 | `orchestrator-gc.sh`, coordinator skill, tests |
| 7. Carryover and verified continuation | C | 4 | context hook/skill/template and tests |
| 8. End-to-end hardening and packaging | E | 5, 6, 7 | README, manifests if required, aggregate tests |

After Task 1, Tasks 2, 3, and 4 are parallel-safe only if their final file sets remain disjoint. Task 7 can run with Task 5 only if it does not edit GC/integration files.

## Task 1: Baseline and capability audit

1. Run `bash orchestrator/tests/run.sh` and `bash orchestrator/codex-tests/run.sh`; record exact baseline evidence in `orchestrator/IMPLEMENTATION-HANDOFF.md`.
2. Write failing contract tests for task DAG, coordinator-only scheduling, distinct child worktrees, thread health checks, integration, and cleanup states.
3. Inspect the installed Codex plugin schema/runtime for lifecycle hooks and transcript/context usage. Do not infer Codex support from Claude's manifest.
4. If unsupported, prohibit unrecognized Claude-style hook syntax and implement only a supported runtime/manual carryover trigger. Never report a fake 65% value.
5. Update the handoff with the ready set and exact continuation prompts.

## Task 2: Approved task DAG

1. Add a machine-readable task-DAG template and a Bash 3.2-compatible validator.
2. Require unique IDs, explicit dependencies, declared files/contracts, verification commands, allowed states, and cycle rejection.
3. Reject parallel-ready tasks that share files or uncoordinated contracts.
4. Require Fable to emit the DAG with `plan.md`.
5. Freeze the validated DAG in coordinator control and hash it with the approved contract.
6. Add focused tests and register them in the shared runner.

## Task 3: Child worktree lifecycle

1. Test `orc-task/<mission>/<task-id>` naming, exact parent tip/base SHA, duplicate refusal, tab/newline rejection, and manifest authority.
2. Create each child from the parent mission tip in its own worktree.
3. Store authoritative task rows in coordinator control; worker copies are untrusted.
4. Refuse a branch/worktree owned by another active task.
5. Keep tests isolated from real repositories/remotes.

## Task 4: Child thread scheduler

1. Replace the single-executor rule with bounded ownership: each child owns one approved task; the coordinator owns scheduling and integration.
2. Ready set requires completed predecessors, no active/completed owner, no file/contract conflict, and no user-approval blocker.
3. Use fresh project-local Codex threads, not forks.
4. Port Codex Loop Engineering health checks: provisional ID, read/list visibility, title, first turn, active/completed status, startup evidence, settings evidence, and one replacement maximum.
5. Child outcomes are durable task state/report/BLOCKED files; the parent must not depend on reading full child chats.
6. Preserve exact sandbox roots and the commit-broker boundary.

## Task 5: Child integration and child GC

1. Test completion, expected branch/base, clean worktree, verified commits, resolved rework, and task/parent verification preconditions.
2. Integrate without rewriting history and record the integrated SHA.
3. Use states `ready -> running -> completed -> integrated -> collected`, with retriable `cleanup_pending`.
4. After verified integration, remove only the exact manifest-recorded child worktree and local branch.
5. Delete a pushed remote branch only after a successful remote-state check.
6. After verified integration and filesystem cleanup, archive the exact accepted
   child Codex task ID so completed task windows do not accumulate in the user’s
   task list. Never archive running, blocked, review, or unresolved-rework tasks.
7. If later Fable rework targets that task, unarchive that exact task, re-provision
   its manifest worktree from the updated parent tip, resume it, and archive it
   again only after reintegration and cleanup.
8. Treat task-window archive/unarchive failures as retriable `cleanup_pending`;
   make repeated resource cleanup and archival idempotent no-ops.

## Task 6: Parent mission GC

1. Run compensating GC during every Phase 0 reconcile before scheduling new work.
2. Verify the recorded parent tip is in the target branch. If PR metadata is available, verify merged status/merge commit as additional evidence.
3. Only after resolved review, clean worktree, exact manifest, and merge proof: remove parent worktree, local `orc/<mission>`, and matching remote branch.
4. Network and transient failures become `cleanup_pending` and retry later.
5. Preserve design, plan, DAG, decisions, report, verification, and cleanup journal in archive.
6. Reconcile every recorded child task window as well as Git resources; archive
   any terminal integrated child whose accepted thread is still visible, while
   preserving all nonterminal or unresolved task windows.

## Task 7: Carryover and continuation

1. Preserve the existing Claude 65% Stop hook.
2. Write carryover and all durable state before requesting a continuation.
3. If Codex exposes a supported lifecycle/context signal, register an adapter that requests one fresh verified continuation task.
4. Otherwise implement the same continuation protocol at the supported coordinator boundary and document that exact automatic context percentage is unavailable.
5. Suppress duplicate continuations; active child execution is never restarted or duplicated.

## Task 8: Verification and documentation

1. Add end-to-end coverage: DAG -> ready children -> child completion -> integration -> child GC -> final review -> target merge -> parent GC.
2. Cover dirty worktrees, unmerged commits, duplicate threads, network failure,
   child-targeted rework, stale provisional IDs, task-window archive failure,
   rework unarchive/rearchive, and repeated cleanup.
3. Run both full test suites and record exact output.
4. Review the diff for unrelated files and unsupported claims.
5. Update README, state diagrams, compatibility/migration notes, and manifests only when required by validated packaging rules.

## Non-negotiable constraints

- Preserve current unrelated changes in `claude-bridge/config.py`, `.DS_Store`, and `figma-swift-tokens.skill`.
- Work only under `orchestrator/` plus implementation handoff/loop planning files.
- TDD for every behavior change.
- No commit, push, PR, merge, publication, or deletion of real branches without separate user authorization.
- No two child writers share a worktree.
- No cleanup by branch-name pattern alone: require exact manifest path, branch, repo, and SHA evidence.
- Never delete dirty, active, unmerged, failed, blocked, review, or rework resources.
