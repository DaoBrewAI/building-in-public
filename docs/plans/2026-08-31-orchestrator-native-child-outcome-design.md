# Orchestrator 0.5.4 Native Child Lifecycle Design

## Goal

Keep the coordinator as a small control plane while every implementation task
runs in a visible same-project native Codex task with its own context and
worktree. No permission question, task failure, broker rejection, review round,
or GC transition may silently create a replacement task.

## Why 0.5.3 passed tests but failed in Desktop

Commit `492756d` replaced the App Server launcher with native `create_thread`
but retained child-owned writes to an external task-state directory. Native
creation has no writable-root grant field, so a synthetic
`native-writable-root-receipt` asserted a capability it could not create.

The tests then reproduced the assertion instead of the real boundary:

- child-thread tests grepped prose;
- adoption tests pre-created the receipt in the parent process;
- E2E manually created worktrees, task health, commits, and archive state;
- broker, outcome, integration, continuation, and GC were tested independently,
  not across their crash windows;
- review-time GC deleted host-owned worktrees before possible rework.

This explains both repeated replacement and parent context exhaustion: after a
child finished, the coordinator also called `read_thread`, replaying much of the
child history back into the parent.

## Final lifecycle

```text
freeze ready node + exact parent SHA
        ↓
create_thread(project=<exact saved project>, worktree=<frozen SHA>)
        ↓
structured list/wait/bootstrap health + exact non-null projectId
        ↓
native-task-health receipt (max 2 attempts; archive receipt before attempt 2)
        ↓
task-worktree adopt (production create/reprovision do not exist)
        ↓
child edits only declared files in its native worktree
        ↓
wait_threads returns one ORC_TASK_OUTCOME_V1 envelope
        ↓
coordinator imports outcome; resident broker waits for completed outcome epoch
        ↓
hook-free, mode-bound broker commit + DONE
        ↓
same child returns completed; coordinator verifies and integrates with
verified merge tree + commit-tree + ref CAS
        ↓
retain every child worktree/window through review and task-outcome reopen
        ↓
clean final review → accepted → archive all native tasks → one batch GC
```

The coordinator never calls terminal `read_thread`; it consumes only the exact
turn ID and final message delivered by `wait_threads`.

## Durable authority

- `native-task-health.py` freezes project/source/title/repository/task-state
  directory/schedule base, derives health failures from structured observation,
  and requires a native archive receipt before one replacement.
- `task-outcome.py` binds thread, turn, task, generation, nonce, Git state, and
  exact schema. Rework advances generation/nonce on the retained child and
  clears only the current latest pointer while preserving the immutable ledger.
- `verify-approved-authority.py` verifies all four frozen approval files and is
  shared by broker, integration, GC, and continuation.
- Broker requests are visible only after a content-addressed outcome exists;
  the broker refuses to consume while outcome intent/state/latest disagree.
- Broker and integration create commits from verified trees with hooks disabled,
  exact parent CAS, immutable intents, and crash recovery.
- Continuation binds planning, native-health, external task-state, broker,
  outcome, rework, integration, cleanup, and frozen-approval authority.
- GC independently requires exact DAG/registry equality, resolved review,
  accepted mission, every window archived, integration evidence, and matching
  control/external task state before deleting any resource.
- Coordinator lifecycle mutations serialize on one mission-scoped lock.

## Cleanup and replacement

Replacement is a bootstrap-health recovery only. Permission denial, BLOCKED,
FAILED, broker rejection, implementation crash, and review finding stay on the
same accepted task. A rejected bootstrap must be archived (or authoritatively
already archived) before attempt two. A second health failure is durable
BLOCKED.

Children integrate one-by-one, but no child is archived or collected before
final review. Rework uses `task-outcome.py reopen` on the same task/worktree;
the removed `reprovision` path can no longer recreate a host-released worktree.

## Release evidence

- focused RED→GREEN coverage for health, outcome, broker, planning, integration,
  GC, continuation, frozen scope, and crash recovery;
- full package and dual-host validation;
- one real Desktop canary for `create_thread → list/wait → project/cwd/tip →
  archive → host worktree release` before release publication.
