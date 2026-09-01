#!/usr/bin/env bash
# App-native worktrees are adopted without creating a second child worktree.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
HEALTH="$ROOT/scripts/native-task-health.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orc-native-adopt.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

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

setup_case() {
  local root="$1"
  REPO="$root/repo"
  PARENT="$root/parent"
  CHILD="$root/native-child"
  CONTROL="$root/hub/control/mission"
  MISSION_DIR="$root/hub/missions/mission"
  TASK_DIR="$root/task-state"
  mkdir -p "$REPO" "$CONTROL" "$MISSION_DIR"
  git init -q "$REPO"
  git -C "$REPO" config user.email native-adopt@example.invalid
  git -C "$REPO" config user.name native-adopt
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit -q --allow-empty -m base
  git -C "$REPO" worktree add -qb orc/mission "$PARENT"
  printf 'parent\n' > "$PARENT/parent.txt"
  git -C "$PARENT" add parent.txt
  git -C "$PARENT" commit -qm parent
  PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
  git -C "$REPO" worktree add -q --detach "$CHILD" "$PARENT_TIP"
  printf 'request\n' > "$MISSION_DIR/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$MISSION_DIR/MISSION.md"
  printf 'planned\n' > "$MISSION_DIR/state"
  printf 'backend: hybrid\nstage: plan\n' > "$MISSION_DIR/session.txt"
}

adopt() {
  local task_id="$1"
  mkdir -p "$TASK_DIR"
  "$HEALTH" begin --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --task-id "$task_id" --project-id project-native-adopt \
    --source-thread-id source-native-adopt \
    --title "ORC mission · $task_id Native adoption" \
    --repo "$REPO" --schedule-base "$PARENT_TIP" >/dev/null 2>&1 || true
  "$HEALTH" observe --control-dir "$CONTROL" --task-id "$task_id" \
    --provisional-id "provisional-$task_id" --thread-id "thread-$task_id" \
    --list-visible true --observed-title "ORC mission · $task_id Native adoption" \
    --bootstrap-state completed --task-state idle --cwd "$CHILD" \
    --tip "$PARENT_TIP" --observed-project-id project-native-adopt \
    >/dev/null 2>&1 || true
  ORC_TASK_WORKTREE_TESTING=1 ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$2" \
    "$LIFECYCLE" adopt --create-mode test-fixture \
      --mission-dir "$MISSION_DIR" --control-dir "$CONTROL" \
      --task-dir "$TASK_DIR" --mission mission --task-id "$task_id" \
      --repo "$REPO" --parent-worktree "$PARENT" --worktree "$CHILD" \
      --thread-id "thread-$task_id"
}

HAPPY="$TMP/happy"
setup_case "$HAPPY"
adopt task-a "$HAPPY" >/dev/null 2>&1
HAPPY_RC=$?
check "native adoption succeeds without creating another worktree" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" branch --show-current)" = orc-task/mission/task-a && "$(git -C "$2" rev-parse HEAD)" = "$3" ]]' \
  _ "$HAPPY_RC" "$CHILD" "$PARENT_TIP"
check "native adoption publishes exact coordinator and worker manifests" bash -c \
  'cmp -s "$1/tasks/task-a/worktrees.txt" "$2/worktrees.txt" && [[ "$(cut -f1 "$1/tasks/task-a/worktrees.txt")" = "$3" ]]' \
  _ "$CONTROL" "$TASK_DIR" "$(cd "$CHILD" && pwd -P)"
check "native adoption publishes ready generation and sandbox authority" bash -c \
  '[[ "$(cat "$1/tasks/task-a/state")" = ready && "$(cat "$2/state")" = ready && "$(cat "$1/tasks/task-a/generation")" = 1 && "$(cat "$1/tasks/task-a/sandbox-root")" = "$3" ]]' \
  _ "$CONTROL" "$TASK_DIR" "$(cd "$CHILD" && pwd -P)"
check "native adoption atomically publishes owner window and one coordinator-owned outcome nonce" bash -c \
  'nonce="$1/tasks/task-a/outcome-nonce"; [[ "$(cat "$1/tasks/task-a/accepted-thread-id")" = thread-task-a && "$(cat "$2/accepted-thread-id")" = thread-task-a && "$(cat "$1/tasks/task-a/task-window-state")" = unarchived && -f "$nonce" && ! -L "$nonce" && "$(wc -l < "$nonce" | tr -d " ")" = 1 && "$(tr -d "\n" < "$nonce")" =~ ^[0-9a-f]{64}$ && -s "$1/tasks/task-a/native-health/accepted.json" && ! -e "$2/outcome-nonce" && ! -e "$1/tasks/task-a/native-writable-root-receipt" && ! -e "$2/native-writable-root-receipt" ]]' \
  _ "$CONTROL" "$TASK_DIR"
check "native adoption leaves exactly one registered child path" bash -c \
  '[[ "$(git -C "$1" worktree list --porcelain | grep -Fxc "worktree $2")" = 1 ]]' \
  _ "$REPO" "$(cd "$CHILD" && pwd -P)"

DIRTY="$TMP/dirty"
setup_case "$DIRTY"
printf 'dirty\n' > "$CHILD/dirty.txt"
adopt task-dirty "$DIRTY" >/dev/null 2>&1
DIRTY_RC=$?
check "dirty native worktree is rejected without ownership publication" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -z "$(git -C "$2" branch --show-current)" && ! -e "$3/tasks/task-dirty/worktrees.txt" && ! -e "$3/tasks/task-dirty/accepted-thread-id" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-dirty' \
  _ "$DIRTY_RC" "$CHILD" "$CONTROL" "$REPO"

WRONG_HEAD="$TMP/wrong-head"
setup_case "$WRONG_HEAD"
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$CHILD" reset -q --hard "$BASE"
adopt task-wrong-head "$WRONG_HEAD" >/dev/null 2>&1
WRONG_HEAD_RC=$?
check "native worktree at a different base is rejected" bash -c \
  '[[ "$1" -ne 0 && -z "$(git -C "$2" branch --show-current)" && ! -e "$3/tasks/task-wrong-head/worktrees.txt" && ! -e "$3/tasks/task-wrong-head/accepted-thread-id" ]]' \
  _ "$WRONG_HEAD_RC" "$CHILD" "$CONTROL"

ATTACHED="$TMP/attached"
setup_case "$ATTACHED"
git -C "$CHILD" switch -qc unrelated
adopt task-attached "$ATTACHED" >/dev/null 2>&1
ATTACHED_RC=$?
check "already attached native worktree is rejected" bash -c \
  '[[ "$1" -ne 0 && "$(git -C "$2" branch --show-current)" = unrelated && ! -e "$3/tasks/task-attached/worktrees.txt" && ! -e "$3/tasks/task-attached/accepted-thread-id" ]]' \
  _ "$ATTACHED_RC" "$CHILD" "$CONTROL"

WORKER_NONCE="$TMP/worker-nonce"
setup_case "$WORKER_NONCE"
mkdir -p "$TASK_DIR"
printf 'untrusted-worker-nonce\n' > "$TASK_DIR/outcome-nonce"
adopt task-worker-nonce "$WORKER_NONCE" >/dev/null 2>&1
WORKER_NONCE_RC=$?
check "worker-side outcome nonce is rejected without ownership publication or overwrite" bash -c \
  '[[ "$1" -ne 0 && -z "$(git -C "$2" branch --show-current)" && ! -e "$3/tasks/task-worker-nonce/worktrees.txt" && ! -e "$3/tasks/task-worker-nonce/accepted-thread-id" && "$(cat "$4/outcome-nonce")" = untrusted-worker-nonce ]]' \
  _ "$WORKER_NONCE_RC" "$CHILD" "$CONTROL" "$TASK_DIR"

BEFORE_ATTACH="$TMP/before-attach"
setup_case "$BEFORE_ATTACH"
ORC_TASK_WORKTREE_TEST_FAIL_BEFORE_ADOPT=1 adopt task-before "$BEFORE_ATTACH" >/dev/null 2>&1
BEFORE_ATTACH_RC=$?
check "pre-attach interruption preserves detached worktree and clears staged authority" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -z "$(git -C "$2" branch --show-current)" && "$(git -C "$2" rev-parse HEAD)" = "$3" && -z "$(git -C "$2" status --porcelain --untracked-files=all)" && ! -e "$4/tasks/task-before/worktrees.txt" && ! -e "$4/tasks/task-before/accepted-thread-id" ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc-task/mission/task-before' \
  _ "$BEFORE_ATTACH_RC" "$CHILD" "$PARENT_TIP" "$CONTROL" "$REPO"
adopt task-before "$BEFORE_ATTACH" >/dev/null 2>&1
check "exact retry succeeds after pre-attach interruption" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" branch --show-current)" = orc-task/mission/task-before && -s "$3/tasks/task-before/worktrees.txt" ]]' \
  _ "$?" "$CHILD" "$CONTROL"

FINALIZE="$TMP/finalize"
setup_case "$FINALIZE"
ORC_TASK_WORKTREE_TEST_FAIL_FINALIZE=1 adopt task-finalize "$FINALIZE" >/dev/null 2>&1
FINALIZE_RC=$?
check "durability failure rolls back branch manifests and native owner authority" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -z "$(git -C "$2" branch --show-current)" && "$(git -C "$2" rev-parse HEAD)" = "$3" && -z "$(git -C "$2" status --porcelain --untracked-files=all)" && ! -e "$4/tasks/task-finalize/worktrees.txt" && ! -e "$4/tasks/task-finalize/accepted-thread-id" && ! -e "$5/accepted-thread-id" ]] && ! git -C "$6" show-ref --verify --quiet refs/heads/orc-task/mission/task-finalize' \
  _ "$FINALIZE_RC" "$CHILD" "$PARENT_TIP" "$CONTROL" "$TASK_DIR" "$REPO"
adopt task-finalize "$FINALIZE" >/dev/null 2>&1
check "exact retry succeeds after durability rollback" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" branch --show-current)" = orc-task/mission/task-finalize && "$(cat "$3/tasks/task-finalize/accepted-thread-id")" = thread-task-finalize ]]' \
  _ "$?" "$CHILD" "$CONTROL"

ROLLBACK="$TMP/rollback"
setup_case "$ROLLBACK"
ORC_TASK_WORKTREE_TEST_FAIL_AFTER_ADOPT=1 adopt task-retry "$ROLLBACK" >/dev/null 2>&1
ROLLBACK_RC=$?
check "interrupted adoption detaches and preserves the native worktree" bash -c \
  '[[ "$1" -ne 0 && -d "$2" && -z "$(git -C "$2" branch --show-current)" && "$(git -C "$2" rev-parse HEAD)" = "$3" && -z "$(git -C "$2" status --porcelain --untracked-files=all)" && ! -e "$4/tasks/task-retry/worktrees.txt" && ! -e "$4/tasks/task-retry/accepted-thread-id" ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc-task/mission/task-retry' \
  _ "$ROLLBACK_RC" "$CHILD" "$PARENT_TIP" "$CONTROL" "$REPO"
adopt task-retry "$ROLLBACK" >/dev/null 2>&1
check "exact retry adopts the preserved native worktree" bash -c \
  '[[ "$1" -eq 0 && "$(git -C "$2" branch --show-current)" = orc-task/mission/task-retry && -s "$3/tasks/task-retry/worktrees.txt" ]]' \
  _ "$?" "$CHILD" "$CONTROL"

echo "  native-child-adoption: $OK/$N"
[[ "$OK" -eq "$N" ]]
