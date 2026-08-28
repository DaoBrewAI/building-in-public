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

check "coordinator owns child creation" "$SKILL" 'coordinator owns authority, scheduling, integration'
check "child cannot schedule another child" "$TASK" 'One child owns one task and never schedules another task'
check "ready set requires integrated predecessors" "$TASK" 'every predecessor is durably `integrated` or `collected`'
check "ready set excludes rework blockers" "$TASK" 'no predecessor has unresolved rework'
check "ready set excludes owners and approvals" "$TASK" 'no accepted owner or approval blocker'
check "ready set excludes file and contract conflicts" "$TASK" 'files/contracts do not overlap any active node'
check "ready set recomputes after integration" "$TASK" 'Recompute after every verified integration'
check "native lifecycle gate precedes thread creation" "$TASK" 'Run the production lifecycle gate before creating a thread'
check "App Server client creates the visible task" "$TASK" 'scripts/codex-task-client.py create'
check "project context uses canonical path" "$TASK" 'exact canonical saved-project root, never labels or'
check "runtime roots are bounded" "$TASK" 'workspace-write only to the child worktree and task state'
check "thread ID remains provisional" "$TASK" 'returned thread ID is provisional'
check "health requires list visibility" "$TASK" 'requires App Server `thread/list` visibility'
check "read alone cannot accept ownership" "$TASK" 'Read evidence alone is not sufficient without list visibility'
check "failed health allows one replacement" "$TASK" 'allow at most one replacement'
check "durable outcome outranks chat" "$TASK" 'Chat text is advisory'
check "task brief forbids scheduling" "$BRIEF" 'Never create child tasks'
check "task brief persists durable outcomes" "$BRIEF" 'durable task state'
check "client uses App Server thread start" "$CLIENT" 'thread/start'
check "rework unarchives exact thread" "$CLEANUP" 'unarchive the exact accepted child thread'
check "rework reprovisions exact retained paths" "$CLEANUP" 'task-worktree.sh reprovision'
check "rework advances generation" "$CLEANUP" 'generation `N+1`'
check "rework resumes same ID" "$CLEANUP" 'resume the same ID'
check "rework never resumes missing worktree" "$CLEANUP" 'Never resume against a collected/missing worktree'
check "rework archives after recollection" "$CLEANUP" 'Rearchive only after verified reintegration'
check "archive failure is retriable" "$CLEANUP" 'task-window-archive-pending'
check "unsafe task states stay visible" "$CLEANUP" 'Never archive running, blocked, review, or unresolved-rework tasks'

echo "  child-thread-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
