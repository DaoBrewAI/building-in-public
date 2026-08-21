#!/usr/bin/env bash
# RED contract for verified child integration and two-level cleanup states.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
GC="$ROOT/scripts/orchestrator-gc.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}
contains() { [[ -f "$1" ]] && grep -Fq -- "$2" "$1"; }

check "child integration script exists and is executable" test -x "$INTEGRATE"
check "integration requires completed child state" contains "$INTEGRATE" "completed"
check "integration verifies the exact child branch namespace" contains "$INTEGRATE" "orc-task/"
check "integration verifies the recorded parent base" contains "$INTEGRATE" "base"
check "integration records the integrated SHA" contains "$INTEGRATE" "integrated_sha"
check "child state machine includes ready through collected" contains "$SKILL" \
  "ready -> running -> completed -> integrated -> collected"
check "cleanup failures are retriable" contains "$SKILL" "cleanup_pending"
check "GC recognizes manifest-recorded child branches" contains "$GC" "orc-task/"
check "GC requires exact task manifest authority" contains "$GC" "task"
check "GC preserves unsafe child resources" contains "$GC" "cleanup_pending"
check "GC remains idempotent after collection" contains "$GC" "collected"
check "completed child windows are archived by exact accepted thread ID" \
  contains "$SKILL" "archive the exact accepted child thread"
check "active and unresolved child windows are preserved" \
  contains "$SKILL" "Never archive running, blocked, review, or unresolved-rework"
check "archive failures are retriable cleanup" \
  contains "$SKILL" "task-window archive failure"
check "task-scoped rework reuses an archived child window" \
  contains "$SKILL" "unarchive the exact accepted child thread"

echo "  child-integration-gc-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
