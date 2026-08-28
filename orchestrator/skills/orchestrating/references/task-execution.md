# Native task execution

Read this file before ready-set computation, child creation/resume, durable
outcome consumption, or task integration.

## Ready set

A DAG node is ready only when every predecessor is durably `integrated` or
`collected`, no predecessor has unresolved rework, the node has no accepted owner or approval blocker,
and its declared files/contracts do not overlap any
active node. Recompute after every verified integration.

## Create a task

Run the production lifecycle gate before creating a thread:

```text
scripts/task-worktree.sh create \
  --mission-dir <mission-dir> \
  --control-dir <control-dir> \
  --task-dir <task-dir> \
  --mission <mission> --task-id <task-id> \
  --repo <repo> --parent-worktree <parent> --worktree <child>
```

The gate validates native authority, the frozen four-entry approval manifest,
exact DAG node, predecessor integration, blockers, ownership, and conflicts
inside the lifecycle lock. Never recreate its logic in the coordinator.

Render `templates/task-brief.md` with exact task/generation, branch/base, files,
contracts, tests, sandbox roots, frozen inputs, task-state path, and commit
request directory. Start its commit broker, then run the App Server client as
the tracked foreground process:

```text
scripts/codex-task-client.py create \
  --cwd <child-worktree> --task-dir <task-dir> \
  --project-root <exact-saved-project-root> \
  --project-id <recorded-parent-project-id> \
  --title "ORC <mission> · <task-id> <title>" \
  --model gpt-5.6-sol --effort high --prompt-file <task-brief>
```

Every child must use the same `projectId` as its coordinator/parent session.
Resolve that ID from the exact canonical saved-project root, never labels or
summaries, record it in coordinator authority, and reuse it for the whole
mission. In Claude Code, run `codex-task-client.py bind-project --project-root
<root>` once before child creation, record the returned ID as parent authority,
and reuse it. Normal child creation never resolves or creates a project. A child with
`projectId=null` or a different project ID is invalid: stop and replace it
before accepting ownership so every child appears under the parent's project.
The runtime grants workspace-write only to the child worktree and task state,
with network off.

## Accept thread ownership

A returned thread ID is provisional. In Codex, use the native task APIs. In
Claude Code, run `codex-task-client.py inspect --thread-id <id>`; the bridge
requires App Server `thread/list` visibility and `thread/read` evidence. Accept
only when the exact ID/title/cwd/Git/project context matches, the first turn is normally active or
completed, startup evidence shows it read the task contract, and requested
model/effort/sandbox/roots/broker settings are recorded. Read evidence alone is
not sufficient without list visibility. On failed health, use the host-native
task API or `codex-task-client.py stop` plus `archive` on the exact provisional task and
allow at most one replacement from the same frozen brief. A second failure is
BLOCKED.

Publish the accepted ID as matching strict one-line fsynced values in both
coordinator and worker task state. One child owns one task and never schedules
another task.

## Durable outcome

The child writes `state`, `report.md`, and when needed `BLOCKED-<n>.md` before
ending. Completed evidence includes branch/base/tip, exact changed files,
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
