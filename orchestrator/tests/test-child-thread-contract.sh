#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TASK="$ROOT/skills/orchestrating/references/task-execution.md"
CLEANUP="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
BRIEF="$ROOT/templates/task-brief.md"
CLIENT="$ROOT/scripts/codex-task-client.py"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
HEALTH="$ROOT/scripts/native-task-health.py"

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
check "native child starts from the frozen schedule base" "$TASK" 'startingState` names the frozen full schedule-base SHA'
check "native setup cannot re-resolve an advanced parent branch" "$TASK" 'Do not resolve the live `orc/<mission>` branch again during native setup'
check "coordinator freezes native health before create" "$TASK" 'native-task-health.py begin'
check "every provisional child has a durable observation" "$TASK" 'native-task-health.py observe'
check "native replacement is capped at two attempts" "$TASK" 'at most two durable provisional attempts'
check "bootstrap follows Loop native health" "$TASK" 'Codex Loop Engineering native health sequence'
check "bootstrap health does not contradict repository-no-write prompt" "$TASK" 'does not require the child to read handoff, skill, or product files before adoption'
check "native bootstrap health uses task APIs" "$TASK" '`wait_threads`, `list_threads`, and one bounded `read_thread`'
check "requested project target is authority" "$TASK" 'requested saved-project target is the ownership authority'
check "project projection is required and exact" "$TASK" 'non-null `projectId` exactly equal to the saved-project request'
check "missing or different project identity is rejected" "$TASK" 'missing or different project identity is a health failure'
check "accepted native worktree is adopted" "$TASK" 'scripts/task-worktree.sh adopt'
check "adoption consumes accepted health receipt" "$TASK" 'consumes the accepted native-health receipt'
check "adoption uses the frozen schedule base" "$TASK" 'child tip must equal that frozen schedule base'
check "advanced live parent is ancestry only" "$TASK" 'live parent tip need only descend the frozen base'
check "adoption binds exact thread ownership" "$TASK" '--thread-id <accepted-formal-thread-id>'
check_absent "adoption requires no writable-root token" "$TASK" '--writable-root-token'
check_absent "production adoption accepts no writable-root token" "$LIFECYCLE" '--writable-root-token'
check_absent "bootstrap requires no external root receipt" "$TASK" 'native-writable-root-receipt'
check_absent "task brief requires no external root receipt" "$BRIEF" 'native-writable-root-receipt'
check_absent "production adoption requires no external root receipt" "$LIFECYCLE" 'native-writable-root-receipt'
check "native task health helper is packaged" "$HEALTH" 'verify-adoption'
check "task brief names frozen schedule authority" "$BRIEF" 'Frozen schedule/base SHA'
check "adoption publishes one coordinator outcome nonce" "$TASK" 'one coordinator-owned `outcome-nonce`'
check "task brief carries the accepted outcome nonce" "$BRIEF" 'outcome nonce'
check "implementation is sent through native lifecycle" "$TASK" 'send_message_to_thread'
check "runtime write scope is the native worktree" "$TASK" 'workspace-write only to the native child worktree'
check "thread ID remains provisional" "$TASK" 'returned thread ID is provisional'
check "health requires list visibility" "$TASK" 'requires native list visibility'
check "read alone cannot accept ownership" "$TASK" 'Read evidence alone is not sufficient without native list visibility'
check "terminal outcome comes directly from wait wake" "$TASK" "consume only that \`wait_threads\` result's exact \`latestTurn.id\` and \`latestAssistantMessage\`"
check "terminal handling forbids history replay" "$TASK" 'Never call `read_thread` after implementation starts'
check "genuine native health failure allows one replacement" "$TASK" 'genuine native launch or identity health failure'
check "permission and task outcomes never cause replacement" "$TASK" 'Permission denials, task failures, `BLOCKED`, and broker outcomes never trigger replacement'
check "durable outcome outranks chat" "$TASK" 'Chat text is advisory'
check "task brief forbids scheduling" "$BRIEF" 'Never create child tasks'
check "task brief persists durable outcomes" "$BRIEF" 'durable task state'
check "client inspects accepted native threads" "$CLIENT" 'thread/read'
check_absent "client never resumes a Desktop-owned thread" "$CLIENT" 'thread/resume'
check_absent "client never creates App Server threads" "$CLIENT" '"thread/start"'
check_absent "client never lists App Server projects" "$CLIENT" 'project/list'
check_absent "client never creates App Server projects" "$CLIENT" 'project/create'
check_absent "client exposes no project-binding command" "$CLIENT" 'bind-project'
check "rework retains exact thread" "$CLEANUP" 'task window still unarchived'
check "rework retains exact worktree" "$CLEANUP" 'exact child worktree still clean and registered'
check "rework advances generation" "$CLEANUP" 'generation `N+1`'
check "rework resumes same ID natively" "$CLEANUP" 'send_message_to_thread` to the same ID'
check "rework uses coordinator reopen authority" "$CLEANUP" 'task-outcome.py reopen'
check "rework rotates outcome epoch" "$CLEANUP" 'refreshes the coordinator-owned outcome nonce'
check "rework crash recovery is durable" "$CLEANUP" 'rework intent'
check "review precedes child archive" "$CLEANUP" 'Only after final review is durably resolved'
check "native archive precedes git collection" "$CLEANUP" 'Native archive is the worktree-release boundary'
check "archive failure is retriable" "$CLEANUP" 'task-window-archive-pending'
check "unsafe task states stay visible" "$CLEANUP" 'Never archive running, blocked, review, or unresolved-rework tasks'

echo "  child-thread-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
