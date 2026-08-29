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

Call `create_thread` with target type `project`, the exact saved-project ID
supplied to the native create request, `environment=worktree`, and a
`startingState` names the exact `orc/<mission>` branch with
`onMissing=error`. Pin GPT-5.6-Sol high. Do not fork.

Create the exact external `<task-dir>`, generate a one-use root token, and use
a deterministic title and repository-no-write bootstrap prompt. Its only write
is the permission receipt:

```text
title: ORC <mission> · <task-id> <title>
target:
  type: project
  projectId: <coordinator-saved-project-id>
  environment:
    type: worktree
    startingState:
      type: branch
      branchName: orc/<mission>
      onMissing: error
prompt:
  Orchestrator bootstrap only. Do not inspect or modify repository files.
  Do not create tasks. Write exactly <bootstrap-root-token> plus one newline to
  <task-dir>/native-writable-root-receipt. Then report cwd, HEAD,
  detached/branch state, and clean status.
```

The returned thread ID is provisional. Worktree setup may first return a client
ID; resolve the formal ID by exact title. Use native `wait_threads`,
`list_threads`, and `read_thread`. Acceptance requires native list
visibility, the exact title and parent `sourceThreadId`, a completed bootstrap
turn, an idle task, and a clean registered detached worktree at the exact parent
tip. Read evidence alone is not sufficient without native list visibility. The
receipt must be a safe exact one-line file; it proves this task can reach the
otherwise external task-state and commit-request directory under current host
policy before implementation begins.

The requested saved-project target is the ownership authority. App Server internal
UUIDs and nullable task-list fields are not. A null or absent `projectId`
projection is unobservable, not a mismatch. Reject only when a non-null project
ID names a different saved project.

On failed health, archive the exact provisional task and allow at most one
replacement from the same frozen request. A second failure is BLOCKED.

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
  --thread-id <accepted-formal-thread-id> \
  --writable-root-token <bootstrap-root-token>
```

The gate holds the lifecycle lock while it revalidates native authority, the
frozen four-entry approval manifest, exact DAG node, predecessors, blockers,
ownership, and conflicts. It accepts only one clean registered worktree,
detached at the exact parent tip, attaches the exact
`orc-task/<mission>/<task-id>` branch, and publishes matching manifests and
generation/sandbox/state authority. The same rollback-covered publication also
binds both accepted-thread-id files, `task-window-state=unarchived`, and the
coordinator copy of `native-writable-root-receipt`. It never creates a second
worktree or leaves a ready task without its owner.

Render `templates/task-brief.md` with the adopted path, exact task/generation,
branch/base, files, contracts, tests, frozen inputs, task-state path, and commit
request directory. Start the commit broker. Publish the accepted formal thread
ID only through the adopt gate above. One child owns one task and never
schedules another task.

## Start and observe implementation

Use native `send_message_to_thread` with the rendered task brief, then
`wait_threads` for completion or attention. Do not stream, poll, or replay
intermediate child items into the coordinator. Use bounded `read_thread` only
after wake to verify the terminal receipt against durable task state and Git.

The verified host policy must allow workspace-write only to the child worktree
and proven task-state directory. Never call App Server `thread/start`,
`thread/resume`, or `turn/start`
for a Desktop-owned task: Desktop already holds its writer. App Server is
lifecycle inspection only for Claude Code.

Claude Code uses the same shared skill, manifests, durable mission state,
worktree lifecycle, and `codex-task-client.py` inspect/archive bridge. If its
host does not expose app-native task creation and messaging, write
`native-task-api-unavailable` and stop before implementation. Never fake
project-local ownership or execute a subtask inside the coordinator context.
For a Claude-owned cleanup retry, use `codex-task-client.py stop` plus
`archive` or `unarchive`; never use it to execute a child.

## Durable outcome

The child writes `state`, `report.md`, and when needed `BLOCKED-<n>.md`
before ending. Completed evidence includes branch/base/tip, exact changed files,
verification commands/raw output, broker request/result, deviations, and risks.
Chat text is advisory. Never schedule or integrate from chat alone.

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
individual integration. Recompute the ready set from durable integration
authority. When every approved node is integrated, set the parent mission to
`executed`, then run the automatic batch child cleanup described in
`cleanup-and-rework.md` before Fable review.
