#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TASK="$ROOT/skills/orchestrating/references/task-execution.md"
CLEANUP="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
BRIEF="$ROOT/templates/task-brief.md"
CLIENT="$ROOT/scripts/codex-task-client.py"

N=0
OK=0
check() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if tr '\n' ' ' < "$file" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_absent() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if ! grep -Fqi -- "$literal" "$file"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check "coordinator owns child creation" "$SKILL" 'coordinator owns authority, scheduling, integration'
check "child cannot schedule another child" "$TASK" 'One child owns one task and never schedules another task'
check "ready set requires integrated predecessors" "$TASK" 'every predecessor is durably `integrated` or `collected`'
check "ready set excludes rework blockers" "$TASK" 'no predecessor has unresolved rework'
check "ready set excludes owners and approvals" "$TASK" 'no accepted owner or approval blocker'
check "ready set excludes file and contract conflicts" "$TASK" 'files/contracts do not overlap any active node'
check "ready set recomputes after integration" "$TASK" 'Recompute after every verified integration'
check "native lifecycle gate precedes implementation" "$TASK" 'Before any implementation, run the production lifecycle gate'
check "app-native API creates the visible task" "$TASK" 'create_thread` with target type `project`'
check "child creation targets the coordinator saved project" "$TASK" 'exact saved-project ID supplied to the native create request'
check "native child gets an independent worktree" "$TASK" 'environment=worktree'
check "native child starts from the mission branch" "$TASK" 'startingState` names the exact `orc/<mission>` branch'
check "bootstrap is repository-no-write except its root proof" "$TASK" 'repository-no-write bootstrap prompt'
check "native health uses task APIs" "$TASK" '`wait_threads`, `list_threads`, and `read_thread`'
check "requested project target is authority" "$TASK" 'requested saved-project target is the ownership authority'
check "nullable projection is not rejected" "$TASK" 'A null or absent `projectId` projection is unobservable, not a mismatch'
check "explicit project mismatch is rejected" "$TASK" 'non-null project ID names a different saved project'
check "accepted native worktree is adopted" "$TASK" 'scripts/task-worktree.sh adopt'
check "adoption binds exact thread ownership" "$TASK" '--thread-id <accepted-formal-thread-id>'
check "adoption verifies external writable root" "$TASK" '--writable-root-token <bootstrap-root-token>'
check "bootstrap writes only the root receipt" "$TASK" 'native-writable-root-receipt'
check "implementation is sent through native lifecycle" "$TASK" 'send_message_to_thread'
check "runtime roots are bounded and proven" "$TASK" 'workspace-write only to the child worktree and proven task-state directory'
check "thread ID remains provisional" "$TASK" 'returned thread ID is provisional'
check "health requires list visibility" "$TASK" 'requires native list visibility'
check "read alone cannot accept ownership" "$TASK" 'Read evidence alone is not sufficient without native list visibility'
check "failed health allows one replacement" "$TASK" 'allow at most one replacement'
check "durable outcome outranks chat" "$TASK" 'Chat text is advisory'
check "task brief forbids scheduling" "$BRIEF" 'Never create child tasks'
check "task brief persists durable outcomes" "$BRIEF" 'durable task state'
check "client inspects accepted native threads" "$CLIENT" 'thread/read'
check_absent "client never resumes a Desktop-owned thread" "$CLIENT" 'thread/resume'
check_absent "client never creates App Server threads" "$CLIENT" '"thread/start"'
check_absent "client never lists App Server projects" "$CLIENT" 'project/list'
check_absent "client never creates App Server projects" "$CLIENT" 'project/create'
check_absent "client exposes no project-binding command" "$CLIENT" 'bind-project'
check "rework unarchives exact thread" "$CLEANUP" 'unarchive the exact accepted child thread'
check "rework reprovisions exact retained paths" "$CLEANUP" 'task-worktree.sh reprovision'
check "rework advances generation" "$CLEANUP" 'generation `N+1`'
check "rework resumes same ID natively" "$CLEANUP" 'send_message_to_thread` to the same ID'
check "rework never sends to a missing worktree" "$CLEANUP" 'Never send against a collected/missing worktree'
check "rework archives after recollection" "$CLEANUP" 'Rearchive only after verified reintegration'
check "archive failure is retriable" "$CLEANUP" 'task-window-archive-pending'
check "unsafe task states stay visible" "$CLEANUP" 'Never archive running, blocked, review, or unresolved-rework tasks'

echo "  child-thread-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
