#!/usr/bin/env bash
# Task 8 production gate: native 0.4 readiness is enforced inside create's lifecycle lock.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-native-gate.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then OK=$((OK + 1)); else echo "  case $N failed: $label"; fi
}

setup_repo() {
  local root="$1"
  REPO="$root/repo"
  PARENT="$root/parent"
  HUB="$root/.orchestrator"
  CONTROL="$HUB/control/mission"
  MISSION_DIR="$HUB/missions/mission"
  mkdir -p "$REPO" "$CONTROL" "$MISSION_DIR" "$root/worktrees" "$root/tasks"
  git init -q "$REPO"
  git -C "$REPO" config user.email gate@example.invalid
  git -C "$REPO" config user.name gate
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit -q --allow-empty -m base
  git -C "$REPO" worktree add -qb orc/mission "$PARENT" >/dev/null
  printf 'request\n' > "$MISSION_DIR/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$MISSION_DIR/MISSION.md"
  printf 'planned\n' > "$MISSION_DIR/state"
  printf 'backend: hybrid\nstage: plan\n' > "$MISSION_DIR/session.txt"
}

make_native_authority() {
  printf '0.4.0\n' > "$CONTROL/pipeline-version"
  printf 'design\n' > "$CONTROL/approved-design.md"
  printf 'plan\n' > "$CONTROL/approved-plan.md"
  printf 'brief\n' > "$CONTROL/brief-exec.md"
  (cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md > approved.sha256)
  cat > "$MISSION_DIR/task-dag.json" <<'JSON'
{"version":1,"mission":"mission","tasks":[
 {"id":"task-a","depends_on":[],"files":["a"],"contracts":["a-api"],"verification":["true"],"state":"ready"},
 {"id":"task-b","depends_on":["task-a"],"files":["shared"],"contracts":["shared-api"],"verification":["true"],"state":"pending"},
 {"id":"task-c","depends_on":["task-b"],"files":["shared"],"contracts":["shared-api"],"verification":["true"],"state":"pending"}
]}
JSON
  "$VALIDATOR" --freeze "$MISSION_DIR/task-dag.json" "$CONTROL" >/dev/null
}

create_task() {
  local task_id="$1" mode="${2:-}" root="$3"
  if [[ -n "$mode" ]]; then
    "$LIFECYCLE" create --create-mode "$mode" --mission-dir "$MISSION_DIR" \
      --control-dir "$CONTROL" --task-dir "$root/tasks/$task_id" \
      --mission mission --task-id "$task_id" --repo "$REPO" \
      --parent-worktree "$PARENT" --worktree "$root/worktrees/$task_id"
  else
    "$LIFECYCLE" create --control-dir "$CONTROL" \
      --task-dir "$root/tasks/$task_id" --mission mission --task-id "$task_id" \
      --repo "$REPO" --parent-worktree "$PARENT" --worktree "$root/worktrees/$task_id"
  fi
}

BYPASS="$TMP/bypass"
setup_repo "$BYPASS"
make_native_authority
create_task task-b "" "$BYPASS" >/dev/null 2>&1
BYPASS_RC=$?
check "native 0.4 direct create without an explicit mode is refused without authority publication" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2/worktrees/task-b" && ! -e "$2/.orchestrator/control/mission/tasks/task-b" ]] && ! git -C "$2/repo" show-ref --verify --quiet refs/heads/orc-task/mission/task-b' \
  _ "$BYPASS_RC" "$BYPASS"

NATIVE="$TMP/native"
setup_repo "$NATIVE"
make_native_authority
create_task unknown native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects a task absent from the frozen DAG" test "$?" -ne 0
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects a dependent task before predecessor integration" test "$?" -ne 0
create_task task-a native-0.4 "$NATIVE" >/dev/null 2>&1
TASK_A_RC=$?
check "native gate creates an exact root task" bash -c \
  '[[ "$1" -eq 0 && -d "$2/worktrees/task-a" && "$(cat "$2/.orchestrator/control/mission/tasks/task-a/state")" = ready ]]' \
  _ "$TASK_A_RC" "$NATIVE"
printf 'integrated\n' > "$CONTROL/tasks/task-a/state"
printf 'integrated\n' > "$NATIVE/tasks/task-a/state"

mkdir -p "$CONTROL/tasks/task-b"
: > "$CONTROL/tasks/task-b/user-approval-blocker"
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects an approval-blocked task" test "$?" -ne 0
rm -f "$CONTROL/tasks/task-b/user-approval-blocker"
: > "$CONTROL/tasks/task-a/unresolved-rework"
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects a predecessor with unresolved rework" test "$?" -ne 0
rm -f "$CONTROL/tasks/task-a/unresolved-rework"
printf 'existing-owner\n' > "$CONTROL/tasks/task-b/accepted-thread-id"
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects an existing task owner" test "$?" -ne 0
rm -f "$CONTROL/tasks/task-b/accepted-thread-id"

mkdir -p "$CONTROL/tasks/task-c"
printf 'ready\n' > "$CONTROL/tasks/task-c/state"
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
check "native gate rejects contradictory active descendant file and contract conflict" test "$?" -ne 0
rm -rf "$CONTROL/tasks/task-c"
create_task task-b native-0.4 "$NATIVE" >/dev/null 2>&1
TASK_B_RC=$?
check "native gate creates the dependent task only after exact readiness" bash -c \
  '[[ "$1" -eq 0 && -d "$2/worktrees/task-b" && "$(cat "$2/.orchestrator/control/mission/tasks/task-b/state")" = ready ]]' \
  _ "$TASK_B_RC" "$NATIVE"

LEGACY="$TMP/legacy"
setup_repo "$LEGACY"
create_task legacy-task legacy "$LEGACY" >/dev/null 2>&1
LEGACY_RC=$?
check "explicit legacy mode preserves classified Hybrid 0.3 create" bash -c \
  '[[ "$1" -eq 0 && -d "$2/worktrees/legacy-task" ]]' _ "$LEGACY_RC" "$LEGACY"

NATIVE_LEGACY="$TMP/native-legacy"
setup_repo "$NATIVE_LEGACY"
make_native_authority
create_task task-a legacy "$NATIVE_LEGACY" >/dev/null 2>&1
check "legacy mode cannot bypass a native 0.4 classification" test "$?" -ne 0

check "orchestrating skill wires child scheduling through the production native gate" bash -c \
  'grep -Fq -- "$1" "$2" && grep -Fq -- "$3" "$2" && grep -Fq -- "$4" "$2"' \
  _ '$PLUGIN_DIR/scripts/task-worktree.sh create' "$SKILL" \
  '--create-mode native-0.4' 'must succeed before rendering or creating the Codex child thread'
check "orchestrating skill preserves only an explicit classified legacy create path" bash -c \
  'grep -Fq -- "$1" "$2" && grep -Fq -- "$3" "$2"' \
  _ '--create-mode legacy' "$SKILL" 'omission of the mode is never a legacy'

echo "  native-schedule-gate-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
