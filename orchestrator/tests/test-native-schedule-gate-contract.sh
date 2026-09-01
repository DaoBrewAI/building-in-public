#!/usr/bin/env bash
# Task 8 production gate: native 0.4 readiness is enforced inside create's lifecycle lock.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
HEALTH="$ROOT/scripts/native-task-health.py"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
SKILL="$ROOT/skills/orchestrating/references/task-execution.md"
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
  printf 'session_id: fable-session\nbackend: claude-headless\nmodel: claude-fable-5\nstage: plan\n' > "$MISSION_DIR/session.txt"
}

make_native_authority() {
  printf '0.4.0\n' > "$CONTROL/pipeline-version"
  printf 'fable-opus\n' > "$MISSION_DIR/planning-backend"
  printf 'fable-opus\n' > "$CONTROL/planning-backend"
  printf 'fable-session\n' > "$CONTROL/planning-session-id"
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
  local task_id="$1" root="$3" task_dir child base title
  task_dir="$root/tasks/$task_id"
  child="$root/worktrees/$task_id"
  base="$(git -C "$PARENT" rev-parse HEAD)"
  title="ORC mission · $task_id Native gate"
  mkdir -p "$task_dir"
  if [[ ! -d "$child" ]]; then
    git -C "$REPO" worktree add -q --detach "$child" "$base" || return 1
  fi
  "$HEALTH" begin --control-dir "$CONTROL" --task-dir "$task_dir" \
    --task-id "$task_id" --project-id project-native-gate \
    --source-thread-id source-native-gate --title "$title" \
    --repo "$REPO" --schedule-base "$base" >/dev/null || return 1
  "$HEALTH" observe --control-dir "$CONTROL" --task-id "$task_id" \
    --provisional-id "provisional-$task_id" --thread-id "thread-$task_id" \
    --list-visible true --observed-title "$title" --bootstrap-state completed \
    --task-state idle --cwd "$child" --tip "$base" \
    --observed-project-id project-native-gate >/dev/null || return 1
  "$LIFECYCLE" adopt --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" \
    --task-dir "$task_dir" --mission mission --task-id "$task_id" \
    --repo "$REPO" --parent-worktree "$PARENT" --worktree "$child" \
    --thread-id "thread-$task_id"
}

BYPASS="$TMP/bypass"
setup_repo "$BYPASS"
make_native_authority
"$LIFECYCLE" create --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" \
  --task-dir "$BYPASS/tasks/task-b" --mission mission --task-id task-b \
  --repo "$REPO" --parent-worktree "$PARENT" --worktree "$BYPASS/worktrees/task-b" \
  >/dev/null 2>&1
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
check "native gate adopts an exact root task" bash -c \
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
check "native gate adopts the dependent task only after exact readiness" bash -c \
  '[[ "$1" -eq 0 && -d "$2/worktrees/task-b" && "$(cat "$2/.orchestrator/control/mission/tasks/task-b/state")" = ready ]]' \
  _ "$TASK_B_RC" "$NATIVE"

for RETAINED_STATE in ready_for_commit blocked failed; do
  RETAINED="$TMP/retained-$RETAINED_STATE"
  setup_repo "$RETAINED"
  make_native_authority
  mkdir -p "$CONTROL/tasks/task-a" "$CONTROL/tasks/task-c"
  printf 'integrated\n' > "$CONTROL/tasks/task-a/state"
  printf '%s\n' "$RETAINED_STATE" > "$CONTROL/tasks/task-c/state"
  create_task task-b native-0.4 "$RETAINED" >/dev/null 2>&1
  check "native gate retains file ownership for $RETAINED_STATE task outcome" test "$?" -ne 0
done

UNVERSIONED="$TMP/unversioned"
setup_repo "$UNVERSIONED"
create_task task-a native-0.4 "$UNVERSIONED" >/dev/null 2>&1
check "unversioned mission cannot enter native task creation" test "$?" -ne 0

FIXTURE_ESCAPE="$TMP/fixture-escape"
setup_repo "$FIXTURE_ESCAPE"
ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT=/ \
  "$LIFECYCLE" create --create-mode test-fixture --mission-dir "$MISSION_DIR" \
    --control-dir "$CONTROL" --task-dir "$FIXTURE_ESCAPE/tasks/task-a" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$FIXTURE_ESCAPE/worktrees/task-a" \
    >/dev/null 2>&1
check "test fixture mode rejects root scope and cannot bypass native authority" test "$?" -ne 0

ADOPT_NATIVE="$TMP/adopt-native"
setup_repo "$ADOPT_NATIVE"
make_native_authority
ADOPT_CHILD="$ADOPT_NATIVE/native-worktree"
git -C "$REPO" worktree add -q --detach "$ADOPT_CHILD" "$(git -C "$PARENT" rev-parse HEAD)"
mkdir -p "$ADOPT_NATIVE/tasks/task-a"
"$HEALTH" begin --control-dir "$CONTROL" --task-dir "$ADOPT_NATIVE/tasks/task-a" \
  --task-id task-a --project-id project-native-gate \
  --source-thread-id source-native-gate --title "ORC mission · task-a Gate" \
  --repo "$REPO" --schedule-base "$(git -C "$PARENT" rev-parse HEAD)" >/dev/null
"$HEALTH" observe --control-dir "$CONTROL" --task-id task-a \
  --provisional-id provisional-task-a --thread-id thread-task-a \
  --list-visible true --observed-title "ORC mission · task-a Gate" \
  --bootstrap-state completed --task-state idle --cwd "$ADOPT_CHILD" \
  --tip "$(git -C "$PARENT" rev-parse HEAD)" \
  --observed-project-id project-native-gate >/dev/null
"$LIFECYCLE" adopt --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" \
  --task-dir "$ADOPT_NATIVE/tasks/task-a" --mission mission --task-id task-a \
  --repo "$REPO" --parent-worktree "$PARENT" --worktree "$ADOPT_CHILD" \
  --thread-id thread-task-a \
  >/dev/null 2>&1
ADOPT_RC=$?
check "production gate adopts an exact app-native root task worktree" bash -c \
  'nonce="$3/tasks/task-a/outcome-nonce"; [[ "$1" -eq 0 && "$(git -C "$2" branch --show-current)" = orc-task/mission/task-a && "$(cat "$3/tasks/task-a/state")" = ready && "$(cat "$3/tasks/task-a/accepted-thread-id")" = thread-task-a && -f "$nonce" && ! -L "$nonce" && "$(wc -l < "$nonce" | tr -d " ")" = 1 && "$(tr -d "\n" < "$nonce")" =~ ^[0-9a-f]{64}$ && ! -e "$4/outcome-nonce" ]]' \
  _ "$ADOPT_RC" "$ADOPT_CHILD" "$CONTROL" "$ADOPT_NATIVE/tasks/task-a"

check "orchestrating skill wires child scheduling through native adoption" bash -c \
  'grep -Fq -- "$1" "$2" && grep -Fq -- "$3" "$2" && grep -Fq -- "$4" "$2"' \
  _ 'scripts/task-worktree.sh adopt' "$SKILL" \
  '--mission-dir <mission-dir>' 'The gate holds the lifecycle lock'

echo "  native-schedule-gate-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
