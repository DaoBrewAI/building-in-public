# Native task execution

Read this file before ready-set computation, child creation, outcome
consumption, or task integration.

## Ready set

A DAG node is ready only when every predecessor is durably `integrated` or
`collected`, no predecessor has unresolved rework, the node has no accepted owner or approval blocker,
and its declared files/contracts do not overlap any
active node. Recompute after every verified integration.

## Bootstrap a visible child

Require the coordinator's exact saved project and its app-native task tools.
Projectless creation is invalid. The saved project must be the task's Git
repository; otherwise write `native-project-worktree-unavailable` before any
implementation instead of falling back into the coordinator context.

Before `create_thread`, freeze the task-state directory, saved-project ID,
current coordinator source task, deterministic title, physical repository, and
exact parent tip with:

```text
scripts/native-task-health.py begin \
  --control-dir <control-dir> --task-dir <task-dir> --task-id <task-id> \
  --project-id <coordinator-saved-project-id> \
  --source-thread-id <coordinator-task-id> --title <exact-title> \
  --repo <repo> --schedule-base <exact-parent-tip>
```

This coordinator-owned request and its `task-state-dir` authority are
immutable. The recorded tip is the task's frozen schedule base.

Call `create_thread` with target type `project`, the exact saved-project ID
supplied to the native create request, `environment=worktree`, and a
`startingState` names the frozen full schedule-base SHA as its exact Git ref.
Do not resolve the live `orc/<mission>` branch again during native setup. Pin
GPT-5.6-Sol high. Do not fork.

Use a deterministic title and a repository-no-write bootstrap prompt:

```text
title: ORC <mission> · <task-id> <title>
target:
  type: project
  projectId: <coordinator-saved-project-id>
  environment:
    type: worktree
    startingState:
      type: branch
      branchName: <frozen-schedule-base-sha>
prompt:
  Orchestrator bootstrap only. Do not inspect or modify repository files.
  Do not create tasks. Report cwd, HEAD, detached/branch state, and clean
  status; then stop.
```

Follow the Codex Loop Engineering native health sequence. The returned thread
ID is provisional. Worktree setup may first return a client ID; resolve the
formal ID by exact title. Use native `wait_threads`, `list_threads`, and one
bounded `read_thread` only for the repository-no-write bootstrap. Acceptance
requires native list visibility, exact title, a completed bootstrap turn, an
idle task, requested model/effort, and one clean registered detached worktree
at the exact frozen schedule base. Read evidence alone is not sufficient
without native list visibility.

This is the Orchestrator bootstrap variant: startup evidence is the completed
requested cwd, HEAD, detached-state, and clean-status report. It intentionally
does not require the child to read handoff, skill, or product files before
adoption. Send the task brief only after the lifecycle gate accepts the native
worktree.

Persist each final provisional observation through
`scripts/native-task-health.py observe`. The helper permits at most two
durable provisional attempts. It derives acceptance or one enumerated native
launch/identity rejection and publishes the accepted receipt; Chat summaries
are not health authority.

The requested saved-project target is the ownership authority, and the current
coordinator source is frozen request provenance. Native list/read must expose a
non-null `projectId` exactly equal to the saved-project request; missing or
different project identity is a health failure. `sourceThreadId` remains a
nullable projection: only a non-null mismatching source is a failure.

Only a genuine native launch or identity health failure derived from structured
list/read/bootstrap observations may archive the exact
provisional task and allow at most one replacement from the same frozen
request: unresolved/unreadable identity, wrong title/source/project/cwd/tip,
missing first turn, or an irrecoverably failed launch. An archived rejected
bootstrap is terminal; never resume or handoff it because its worktree may no
longer exist. Permission denials, task failures, `BLOCKED`, and broker outcomes
never trigger replacement. Before attempt two, persist the exact native
archive/already-archived receipt for attempt one's rejected thread. A second
genuine native health failure is BLOCKED.

## Adopt the native worktree

Before any implementation, run the production lifecycle gate:

```text
scripts/task-worktree.sh adopt \
  --mission-dir <mission-dir> \
  --control-dir <control-dir> \
  --task-dir <task-dir> \
  --mission <mission> --task-id <task-id> \
  --repo <repo> --parent-worktree <parent> \
  --worktree <native-thread-cwd> \
  --thread-id <accepted-formal-thread-id>
```

The gate holds the lifecycle lock while it consumes the accepted native-health
receipt and revalidates native authority, the frozen four-entry approval
manifest, exact DAG node, predecessors, blockers, ownership, and conflicts. The
accepted child tip must equal that frozen schedule base; the live parent tip
need only descend the frozen base, so a parallel sibling integration cannot
invalidate a healthy child. It accepts only one clean registered worktree,
detached at the frozen base, attaches the exact
`orc-task/<mission>/<task-id>` branch, and publishes matching manifests and
generation/sandbox/state authority. The same rollback-covered publication also
binds both accepted-thread-id files, `task-window-state=unarchived`, and one
coordinator-owned `outcome-nonce`. It never creates a second worktree or leaves
a ready task without its owner.

Render `templates/task-brief.md` with the adopted path, exact task/generation,
outcome nonce, branch/base, files, contracts, tests, and frozen inputs. Publish
the accepted formal thread ID only through the adopt gate above. One child owns
one task and never schedules another task. The coordinator owns the external
task-state directory and commit broker; the child receives no external writable
root.

## Start and observe implementation

Write coordinator task state `running`, use native `send_message_to_thread` with
the rendered task brief, then `wait_threads` for completion or attention. Do
not stream, poll, or replay intermediate child items into the coordinator. The
child has workspace-write only to the native child worktree.

At wake, consume only that `wait_threads` result's exact `latestTurn.id` and
`latestAssistantMessage`. Accept one exact final `ORC_TASK_OUTCOME_V1` envelope
from the accepted formal thread, then run coordinator-owned
`scripts/task-outcome.py record`. Never call `read_thread` after implementation
starts: even a bounded read can replay the child turn history into the
coordinator context. The helper binds thread, turn, task, generation, outcome
nonce, Git base/tip, and strict schema before publishing a content-addressed
immutable outcome and mirrored external task state. Unbound Chat text is
advisory and never schedules, commits, or integrates work.

- `ready_for_commit`: the coordinator reruns the frozen verification, derives
  actual dirty paths, writes the v1 broker request bound to task/generation/
  thread/nonce/base/content digest, and runs the broker. Send DONE or REJECTED
  to the same accepted child; broker rejection never creates a replacement.
- `blocked`: the helper writes durable BLOCKED evidence. Mediate it and message
  the same child without replacing or archiving it.
- `failed`: preserve its worktree/thread and durable failure evidence.
- `completed`: require the brokered exact tip and coordinator-run post-commit
  verification before the helper publishes `verification.sha`, report, and
  completed state.

Never call App Server `thread/start`,
`thread/resume`, or `turn/start`
for a Desktop-owned task: Desktop already holds its writer. App Server is
lifecycle inspection only for Claude Code.

Claude Code uses the same shared skill, manifests, durable mission state,
worktree lifecycle, and `codex-task-client.py` inspect/archive bridge. If its
host does not expose app-native task creation and messaging, write
`native-task-api-unavailable` and stop before implementation. Never fake
project-local ownership or execute a subtask inside the coordinator context.
Use `codex-task-client.py outcome --thread-id <id> --turn-id <wake-turn-id>`
only for the bounded exact latest terminal envelope; it never searches an older
turn and never executes or resumes a Desktop-owned task.
For a Claude-owned cleanup retry, use `codex-task-client.py stop` plus
`archive`; never use it to execute a child or revive a host-released worktree.

## Durable outcome

The child edits only declared product files and returns a strict native outcome;
it never writes external state, report, BLOCKED, verification, or broker files.
The coordinator validates and persists those artifacts. Completed evidence
includes accepted thread/turn, generation/nonce, branch/base/tip, exact changed
files, broker request/result, coordinator-run verification, deviations, and
risks. Chat text is advisory until the bound envelope has passed the helper and
Git verification.

## Integrate

Run `scripts/integrate-task.sh` with exact control/task/mission IDs, parent and
child worktrees, and expected parent tip. It requires completed state, exact
manifest/branch/base/tips, clean worktrees, verification attestations, brokered
commit evidence, and no unresolved rework. Hold the lifecycle lock across the
final tip check, merge, and authority publication. Merge the immutable child-tip
SHA with a normal merge commit; never rebase, squash, amend, reset, or force
rewrite task history. A verified repeat is an idempotent no-op.

After integration, keep the child state `integrated` and retain its exact
worktree, branch, and visible task window. Do not run GC or archive a child after
individual integration or before selected-backend review. Recompute the ready
set from durable integration authority. When every approved node is integrated,
set the parent mission to `executed` and run review while every original child
remains available for same-thread rework. Batch collection happens only after a
clean final review and acceptance, as described in `cleanup-and-rework.md`.

When review maps a finding to an integrated task, the coordinator runs
`task-outcome.py reopen` for that retained child and exact expected generation,
then sends the bounded rework brief to its existing accepted thread. Do not
unarchive, fork, replace, or create another worktree/task for it. The reopened
generation follows the same outcome, broker, verification, and integration path
above.
