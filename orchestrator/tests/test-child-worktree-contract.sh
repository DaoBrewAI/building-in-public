#!/usr/bin/env bash
# Contract for one isolated worktree per child task.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE_REAL="$ROOT/scripts/task-worktree.sh"
export ORC_TEST_LIFECYCLE_REAL="$LIFECYCLE_REAL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ORC_TASK_WORKTREE_TESTING=1
export ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT="$TMP"
LIFECYCLE="$TMP/task-worktree-fixture-wrapper.sh"
cat > "$LIFECYCLE" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == create ]]; then
  shift
  control=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == --control-dir ]]; then control="$argument"; break; fi
    previous="$argument"
  done
  hub="${control%/control/mission}"
  mission_dir="$hub/missions/mission"
  mkdir -p "$mission_dir"
  printf 'request\n' > "$mission_dir/request.md"
  printf 'Briefs: brief.md, brief-exec.md\n' > "$mission_dir/MISSION.md"
  printf 'planned\n' > "$mission_dir/state"
  printf 'backend: hybrid\nstage: plan\n' > "$mission_dir/session.txt"
  exec "$ORC_TEST_LIFECYCLE_REAL" create --create-mode test-fixture --mission-dir "$mission_dir" "$@"
fi
exec "$ORC_TEST_LIFECYCLE_REAL" "$@"
SH
chmod +x "$LIFECYCLE"
TMP_PHYS="$(cd "$TMP" && pwd -P)"
REAL_ROOT="$TMP/real-root"
ALIAS_ROOT="$TMP/alias-root"
mkdir -p "$REAL_ROOT"
ln -s "$REAL_ROOT" "$ALIAS_ROOT"
REPO="$ALIAS_ROOT/repo"
PARENT="$ALIAS_ROOT/parent"
CHILD="$ALIAS_ROOT/child-a"
TASK_DIR="$TMP/task-a"
CONTROL="$TMP/main-hub/control/mission"
mkdir -p "$TASK_DIR" "$CONTROL"

git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -q --allow-empty -m base
git -C "$REPO" worktree add -qb orc/mission "$PARENT"
printf 'parent tip\n' > "$PARENT/parent.txt"
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  add parent.txt
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -qm parent-tip
PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
REPO_PHYS="$(cd "$REPO" && pwd -P)"
CHILD_PHYS="$(cd "$(dirname "$CHILD")" && pwd -P)/$(basename "$CHILD")"

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

NESTED_CHILD="$PARENT/nested-child"
NESTED_TASK_DIR="$TMP/task-nested"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$NESTED_TASK_DIR" \
  --mission mission --task-id nested --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$NESTED_CHILD" >/dev/null 2>&1
NESTED_RC=$?
NESTED_PARENT_STATUS="$(git -C "$PARENT" status --porcelain --untracked-files=all)"
check "child nested under parent is refused without mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" && ! -e "$4" && -z "$5" ]] && ! git -C "$6" show-ref --verify --quiet refs/heads/orc-task/mission/nested' _ "$NESTED_RC" "$NESTED_CHILD" "$NESTED_TASK_DIR" "$CONTROL/tasks/nested/worktrees.txt" "$NESTED_PARENT_STATUS" "$REPO"

EQUAL_CHILD="$TMP/equal-child"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$EQUAL_CHILD" \
  --mission mission --task-id task-equal --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$EQUAL_CHILD" >/dev/null 2>&1
EQUAL_RC=$?
check "task dir equal to child is refused without mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-equal' _ "$EQUAL_RC" "$EQUAL_CHILD" "$CONTROL/tasks/task-equal/worktrees.txt" "$REPO"

INSIDE_CHILD="$TMP/inside-child"
INSIDE_TASK_DIR="$INSIDE_CHILD/task"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$INSIDE_TASK_DIR" \
  --mission mission --task-id task-inside --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$INSIDE_CHILD" >/dev/null 2>&1
INSIDE_RC=$?
check "task dir inside child is refused without mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" && ! -e "$4" ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc-task/mission/task-inside' _ "$INSIDE_RC" "$INSIDE_CHILD" "$INSIDE_TASK_DIR" "$CONTROL/tasks/task-inside/worktrees.txt" "$REPO"

DOTDOT_PARENT_ALIAS="$TMP/parent"
ln -s "$PARENT" "$DOTDOT_PARENT_ALIAS"
DOTDOT_TASK_DIR="$TMP/missing/../parent/injected"
DOTDOT_CHILD="$TMP/dotdot-child"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$DOTDOT_TASK_DIR" \
  --mission mission --task-id task-dotdot --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$DOTDOT_CHILD" >/dev/null 2>&1
DOTDOT_RC=$?
check "missing dot-dot task alias is refused without parent mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" && ! -e "$4" && ! -e "$5" ]] && ! git -C "$6" show-ref --verify --quiet refs/heads/orc-task/mission/task-dotdot' _ "$DOTDOT_RC" "$TMP/missing" "$PARENT/injected" "$DOTDOT_CHILD" "$CONTROL/tasks/task-dotdot/worktrees.txt" "$REPO"

DOT_BASE="$TMP/dot-base"
DOT_TASK_DIR="$DOT_BASE/./task"
DOT_CHILD="$TMP/dot-child"
mkdir -p "$DOT_BASE"
"$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$DOT_TASK_DIR" \
  --mission mission --task-id task-dot --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$DOT_CHILD" >/dev/null 2>&1
DOT_RC=$?
check "dot task alias is refused without mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" && ! -e "$4" ]] && ! git -C "$5" show-ref --verify --quiet refs/heads/orc-task/mission/task-dot' _ "$DOT_RC" "$DOT_TASK_DIR" "$DOT_CHILD" "$CONTROL/tasks/task-dot/worktrees.txt" "$REPO"

SYMLINK_TASK="$TMP/symlink-worker"
SYMLINK_CONTROL="$TMP/symlink-hub/control/mission"
SYMLINK_CHILD="$TMP/symlink-child"
mkdir -p "$SYMLINK_TASK/authority-target" "$SYMLINK_CONTROL"
ln -s "$SYMLINK_TASK/authority-target" "$SYMLINK_CONTROL/tasks"
"$LIFECYCLE" create --control-dir "$SYMLINK_CONTROL" --task-dir "$SYMLINK_TASK" \
  --mission mission --task-id task-symlink --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SYMLINK_CHILD" >/dev/null 2>&1
SYMLINK_RC=$?
check "symlinked control tasks path is refused without escape" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-symlink' _ "$SYMLINK_RC" "$SYMLINK_CHILD" "$SYMLINK_TASK/authority-target/task-symlink/worktrees.txt" "$REPO"

COMPONENT_TASK="$TMP/component-worker"
COMPONENT_CONTROL="$TMP/component-hub/control/mission"
COMPONENT_CHILD="$TMP/component-child"
mkdir -p "$COMPONENT_TASK/authority-target" "$COMPONENT_CONTROL/tasks"
ln -s "$COMPONENT_TASK/authority-target" "$COMPONENT_CONTROL/tasks/task-component"
"$LIFECYCLE" create --control-dir "$COMPONENT_CONTROL" --task-dir "$COMPONENT_TASK" \
  --mission mission --task-id task-component --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$COMPONENT_CHILD" >/dev/null 2>&1
COMPONENT_RC=$?
check "symlinked control task component is refused without escape" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-component' _ "$COMPONENT_RC" "$COMPONENT_CHILD" "$COMPONENT_TASK/authority-target/worktrees.txt" "$REPO"

DIRECT_TASK="$TMP/direct-worker"
DIRECT_CONTROL="$DIRECT_TASK/hub/control/mission"
DIRECT_CHILD="$TMP/direct-child"
mkdir -p "$DIRECT_CONTROL"
"$LIFECYCLE" create --control-dir "$DIRECT_CONTROL" --task-dir "$DIRECT_TASK" \
  --mission mission --task-id task-direct --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$DIRECT_CHILD" >/dev/null 2>&1
DIRECT_RC=$?
check "authority inside worker root is refused before mutation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" ]] && ! git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-direct' _ "$DIRECT_RC" "$DIRECT_CHILD" "$DIRECT_CONTROL/tasks/task-direct" "$REPO"

ROLLBACK_CHILD="$ALIAS_ROOT/rollback-child"
ROLLBACK_CHILD_PHYS="$(cd "$(dirname "$ROLLBACK_CHILD")" && pwd -P)/$(basename "$ROLLBACK_CHILD")"
ROLLBACK_TASK_DIR="$TMP/rollback-task"
ROLLBACK_CONTROL="$TMP/rollback-hub/control/mission"
mkdir -p "$ROLLBACK_CONTROL"
ORC_TASK_WORKTREE_TEST_FAIL_AFTER_ADD=1 "$LIFECYCLE" create \
  --control-dir "$ROLLBACK_CONTROL" --task-dir "$ROLLBACK_TASK_DIR" \
  --mission mission --task-id task-rollback --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$ROLLBACK_CHILD" >/dev/null 2>&1
INJECT_RC=$?
ROLLBACK_CLEAN=0
if [[ ! -e "$ROLLBACK_CHILD" && ! -e "$ROLLBACK_CONTROL/tasks/task-rollback/worktrees.txt" && \
  ! -e "$ROLLBACK_TASK_DIR/worktrees.txt" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-rollback && \
  ! git -C "$REPO" worktree list --porcelain | grep -Fxq "worktree $ROLLBACK_CHILD_PHYS"; then
  ROLLBACK_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$ROLLBACK_CONTROL" --task-dir "$ROLLBACK_TASK_DIR" \
  --mission mission --task-id task-rollback --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$ROLLBACK_CHILD" >/dev/null 2>&1
RETRY_RC=$?
check "post-create failure rolls back exact resources and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && -s "$6" && "$(git -C "$4" branch --show-current)" = "orc-task/mission/task-rollback" ]]' _ "$INJECT_RC" "$ROLLBACK_CLEAN" "$RETRY_RC" "$ROLLBACK_CHILD" "$ROLLBACK_CONTROL/tasks/task-rollback/worktrees.txt" "$ROLLBACK_TASK_DIR/worktrees.txt"

SIGNAL_BIN="$TMP/signal-bin"
mkdir -p "$SIGNAL_BIN"
REAL_GIT="$(command -v git)"
REAL_LN="$(command -v ln)"
REAL_CP="$(command -v cp)"
cat > "$SIGNAL_BIN/git" <<'SIGNAL_GIT'
#!/usr/bin/env bash
set -u

ARGS=" $* "
"$ORC_SIGNAL_REAL_GIT" "$@"
RC=$?
if [[ "$RC" -eq 0 && -n "${ORC_SIGNAL_GIT_WORKTREE:-}" && \
  "$ARGS" == *" worktree add "* && "$ARGS" == *" $ORC_SIGNAL_GIT_WORKTREE "* ]]; then
  kill -TERM "$PPID"
  sleep 0.2
fi
exit "$RC"
SIGNAL_GIT
cat > "$SIGNAL_BIN/ln" <<'SIGNAL_LN'
#!/usr/bin/env bash
set -u

LAST_ARG=""
for ARG in "$@"; do
  LAST_ARG="$ARG"
done
"$ORC_SIGNAL_REAL_LN" "$@"
RC=$?
if [[ "$RC" -eq 0 && -n "${ORC_SIGNAL_LN_TARGET:-}" && "$LAST_ARG" == "$ORC_SIGNAL_LN_TARGET" ]]; then
  kill -TERM "$PPID"
  sleep 0.2
fi
exit "$RC"
SIGNAL_LN
cat > "$SIGNAL_BIN/cp" <<'SIGNAL_CP'
#!/usr/bin/env bash
set -u

LAST_ARG=""
for ARG in "$@"; do
  LAST_ARG="$ARG"
done
"$ORC_SIGNAL_REAL_CP" "$@"
RC=$?
if [[ "$RC" -eq 0 && -n "${ORC_SIGNAL_CP_PREFIX:-}" && "$LAST_ARG" == "$ORC_SIGNAL_CP_PREFIX"* ]]; then
  kill -TERM "$PPID"
  sleep 0.2
fi
exit "$RC"
SIGNAL_CP
chmod +x "$SIGNAL_BIN/git" "$SIGNAL_BIN/ln" "$SIGNAL_BIN/cp"

SIGNAL_ADD_CONTROL="$TMP/signal-add-hub/control/mission"
SIGNAL_ADD_TASK_DIR="$TMP/signal-add-task"
SIGNAL_ADD_CHILD="$ALIAS_ROOT/signal-add-child"
SIGNAL_ADD_CHILD_PHYS="$(cd "$(dirname "$SIGNAL_ADD_CHILD")" && pwd -P)/$(basename "$SIGNAL_ADD_CHILD")"
mkdir -p "$SIGNAL_ADD_CONTROL"
PATH="$SIGNAL_BIN:$PATH" ORC_SIGNAL_REAL_GIT="$REAL_GIT" \
  ORC_SIGNAL_REAL_LN="$REAL_LN" ORC_SIGNAL_REAL_CP="$REAL_CP" \
  ORC_SIGNAL_GIT_WORKTREE="$SIGNAL_ADD_CHILD_PHYS" \
  "$LIFECYCLE" create --control-dir "$SIGNAL_ADD_CONTROL" --task-dir "$SIGNAL_ADD_TASK_DIR" \
  --mission mission --task-id task-signal-add --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_ADD_CHILD" >/dev/null 2>&1
SIGNAL_ADD_RC=$?
SIGNAL_ADD_CLEAN=0
if [[ ! -e "$SIGNAL_ADD_CHILD" && ! -e "$SIGNAL_ADD_CONTROL/tasks/task-signal-add/worktrees.txt" && \
  ! -e "$SIGNAL_ADD_TASK_DIR/worktrees.txt" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-signal-add && \
  ! git -C "$REPO" worktree list --porcelain | grep -Fxq "worktree $SIGNAL_ADD_CHILD_PHYS"; then
  SIGNAL_ADD_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$SIGNAL_ADD_CONTROL" --task-dir "$SIGNAL_ADD_TASK_DIR" \
  --mission mission --task-id task-signal-add --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_ADD_CHILD" >/dev/null 2>&1
SIGNAL_ADD_RETRY_RC=$?
check "signal after worktree add rolls back exact resources and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && -s "$6" ]]' _ "$SIGNAL_ADD_RC" "$SIGNAL_ADD_CLEAN" "$SIGNAL_ADD_RETRY_RC" "$SIGNAL_ADD_CHILD" "$SIGNAL_ADD_CONTROL/tasks/task-signal-add/worktrees.txt" "$SIGNAL_ADD_TASK_DIR/worktrees.txt"

SIGNAL_LOCK_CONTROL="$TMP/signal-lock-hub/control/mission"
SIGNAL_LOCK_TASK_DIR="$TMP/signal-lock-task"
SIGNAL_LOCK_CHILD="$ALIAS_ROOT/signal-lock-child"
mkdir -p "$SIGNAL_LOCK_CONTROL"
SIGNAL_LOCK_CONTROL_PHYS="$(cd "$SIGNAL_LOCK_CONTROL" && pwd -P)"
PATH="$SIGNAL_BIN:$PATH" ORC_SIGNAL_REAL_GIT="$REAL_GIT" \
  ORC_SIGNAL_REAL_LN="$REAL_LN" ORC_SIGNAL_REAL_CP="$REAL_CP" \
  ORC_SIGNAL_LN_TARGET="$SIGNAL_LOCK_CONTROL_PHYS/.task-worktree.lock" \
  "$LIFECYCLE" create --control-dir "$SIGNAL_LOCK_CONTROL" --task-dir "$SIGNAL_LOCK_TASK_DIR" \
  --mission mission --task-id task-signal-lock --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_LOCK_CHILD" >/dev/null 2>&1
SIGNAL_LOCK_RC=$?
SIGNAL_LOCK_CLEAN=0
if [[ ! -e "$SIGNAL_LOCK_CHILD" && ! -e "$SIGNAL_LOCK_CONTROL/tasks/task-signal-lock/worktrees.txt" && \
  ! -e "$SIGNAL_LOCK_TASK_DIR/worktrees.txt" && \
  -z "$(find "$SIGNAL_LOCK_CONTROL" -maxdepth 1 -name '.task-worktree.lock*' -print -quit)" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-signal-lock; then
  SIGNAL_LOCK_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$SIGNAL_LOCK_CONTROL" --task-dir "$SIGNAL_LOCK_TASK_DIR" \
  --mission mission --task-id task-signal-lock --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_LOCK_CHILD" >/dev/null 2>&1
SIGNAL_LOCK_RETRY_RC=$?
check "signal after lock publication leaves no residual owner and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && ! -e "$6" ]]' _ "$SIGNAL_LOCK_RC" "$SIGNAL_LOCK_CLEAN" "$SIGNAL_LOCK_RETRY_RC" "$SIGNAL_LOCK_CHILD" "$SIGNAL_LOCK_CONTROL/tasks/task-signal-lock/worktrees.txt" "$SIGNAL_LOCK_CONTROL/.task-worktree.lock"

SIGNAL_CONTROL_CONTROL="$TMP/signal-control-manifest-hub/control/mission"
SIGNAL_CONTROL_TASK_DIR="$TMP/signal-control-manifest-task"
SIGNAL_CONTROL_CHILD="$ALIAS_ROOT/signal-control-manifest-child"
mkdir -p "$SIGNAL_CONTROL_CONTROL"
SIGNAL_CONTROL_CONTROL_PHYS="$(cd "$SIGNAL_CONTROL_CONTROL" && pwd -P)"
SIGNAL_CONTROL_MANIFEST="$SIGNAL_CONTROL_CONTROL_PHYS/tasks/task-signal-control/worktrees.txt"
PATH="$SIGNAL_BIN:$PATH" ORC_SIGNAL_REAL_GIT="$REAL_GIT" \
  ORC_SIGNAL_REAL_LN="$REAL_LN" ORC_SIGNAL_REAL_CP="$REAL_CP" \
  ORC_SIGNAL_LN_TARGET="$SIGNAL_CONTROL_MANIFEST" \
  "$LIFECYCLE" create --control-dir "$SIGNAL_CONTROL_CONTROL" --task-dir "$SIGNAL_CONTROL_TASK_DIR" \
  --mission mission --task-id task-signal-control --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_CONTROL_CHILD" >/dev/null 2>&1
SIGNAL_CONTROL_RC=$?
SIGNAL_CONTROL_CLEAN=0
if [[ ! -e "$SIGNAL_CONTROL_CHILD" && ! -e "$SIGNAL_CONTROL_MANIFEST" && \
  ! -e "$SIGNAL_CONTROL_TASK_DIR/worktrees.txt" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-signal-control; then
  SIGNAL_CONTROL_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$SIGNAL_CONTROL_CONTROL" --task-dir "$SIGNAL_CONTROL_TASK_DIR" \
  --mission mission --task-id task-signal-control --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_CONTROL_CHILD" >/dev/null 2>&1
SIGNAL_CONTROL_RETRY_RC=$?
check "signal after coordinator manifest link removes only owned inode and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && -s "$6" ]]' _ "$SIGNAL_CONTROL_RC" "$SIGNAL_CONTROL_CLEAN" "$SIGNAL_CONTROL_RETRY_RC" "$SIGNAL_CONTROL_CHILD" "$SIGNAL_CONTROL_MANIFEST" "$SIGNAL_CONTROL_TASK_DIR/worktrees.txt"

SIGNAL_COPY_CONTROL="$TMP/signal-copy-hub/control/mission"
SIGNAL_COPY_TASK_DIR="$TMP/signal-copy-task"
SIGNAL_COPY_CHILD="$ALIAS_ROOT/signal-copy-child"
mkdir -p "$SIGNAL_COPY_CONTROL"
PATH="$SIGNAL_BIN:$PATH" ORC_SIGNAL_REAL_GIT="$REAL_GIT" \
  ORC_SIGNAL_REAL_LN="$REAL_LN" ORC_SIGNAL_REAL_CP="$REAL_CP" \
  ORC_SIGNAL_CP_PREFIX="$TMP_PHYS/signal-copy-task/.worktrees.txt." \
  "$LIFECYCLE" create --control-dir "$SIGNAL_COPY_CONTROL" --task-dir "$SIGNAL_COPY_TASK_DIR" \
  --mission mission --task-id task-signal-copy --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_COPY_CHILD" >/dev/null 2>&1
SIGNAL_COPY_RC=$?
SIGNAL_COPY_CLEAN=0
if [[ ! -e "$SIGNAL_COPY_CHILD" && ! -e "$SIGNAL_COPY_CONTROL/tasks/task-signal-copy/worktrees.txt" && \
  ! -e "$SIGNAL_COPY_TASK_DIR/worktrees.txt" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-signal-copy; then
  SIGNAL_COPY_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$SIGNAL_COPY_CONTROL" --task-dir "$SIGNAL_COPY_TASK_DIR" \
  --mission mission --task-id task-signal-copy --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_COPY_CHILD" >/dev/null 2>&1
SIGNAL_COPY_RETRY_RC=$?
check "signal after worker manifest copy rolls back pre-owned temporary and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && -s "$6" ]]' _ "$SIGNAL_COPY_RC" "$SIGNAL_COPY_CLEAN" "$SIGNAL_COPY_RETRY_RC" "$SIGNAL_COPY_CHILD" "$SIGNAL_COPY_CONTROL/tasks/task-signal-copy/worktrees.txt" "$SIGNAL_COPY_TASK_DIR/worktrees.txt"

SIGNAL_WORKER_CONTROL="$TMP/signal-worker-manifest-hub/control/mission"
SIGNAL_WORKER_TASK_DIR="$TMP/signal-worker-manifest-task"
SIGNAL_WORKER_CHILD="$ALIAS_ROOT/signal-worker-manifest-child"
mkdir -p "$SIGNAL_WORKER_CONTROL"
SIGNAL_WORKER_MANIFEST="$TMP_PHYS/signal-worker-manifest-task/worktrees.txt"
PATH="$SIGNAL_BIN:$PATH" ORC_SIGNAL_REAL_GIT="$REAL_GIT" \
  ORC_SIGNAL_REAL_LN="$REAL_LN" ORC_SIGNAL_REAL_CP="$REAL_CP" \
  ORC_SIGNAL_LN_TARGET="$SIGNAL_WORKER_MANIFEST" \
  "$LIFECYCLE" create --control-dir "$SIGNAL_WORKER_CONTROL" --task-dir "$SIGNAL_WORKER_TASK_DIR" \
  --mission mission --task-id task-signal-worker --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_WORKER_CHILD" >/dev/null 2>&1
SIGNAL_WORKER_RC=$?
SIGNAL_WORKER_CLEAN=0
if [[ ! -e "$SIGNAL_WORKER_CHILD" && ! -e "$SIGNAL_WORKER_CONTROL/tasks/task-signal-worker/worktrees.txt" && \
  ! -e "$SIGNAL_WORKER_MANIFEST" ]] && \
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/orc-task/mission/task-signal-worker; then
  SIGNAL_WORKER_CLEAN=1
fi
"$LIFECYCLE" create --control-dir "$SIGNAL_WORKER_CONTROL" --task-dir "$SIGNAL_WORKER_TASK_DIR" \
  --mission mission --task-id task-signal-worker --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$SIGNAL_WORKER_CHILD" >/dev/null 2>&1
SIGNAL_WORKER_RETRY_RC=$?
check "signal after worker manifest link removes only owned inode and retry succeeds" bash -c \
  '[[ "$1" -ne 0 && "$2" -eq 1 && "$3" -eq 0 && -d "$4" && -s "$5" && -s "$6" ]]' _ "$SIGNAL_WORKER_RC" "$SIGNAL_WORKER_CLEAN" "$SIGNAL_WORKER_RETRY_RC" "$SIGNAL_WORKER_CHILD" "$SIGNAL_WORKER_CONTROL/tasks/task-signal-worker/worktrees.txt" "$SIGNAL_WORKER_MANIFEST"

RACE_PARENT_B="$ALIAS_ROOT/race-parent-b"
git -C "$REPO" worktree add -qb orc/race-b "$RACE_PARENT_B"
RACE_CONTROL="$TMP/race-hub/control/mission"
RACE_TASK_DIR="$TMP/race-task"
RACE_CHILD="$ALIAS_ROOT/race-child"
RACE_CHILD_PHYS="$(cd "$(dirname "$RACE_CHILD")" && pwd -P)/$(basename "$RACE_CHILD")"
RACE_BIN="$TMP/race-bin"
RACE_SYNC="$TMP/race-sync"
mkdir -p "$RACE_CONTROL" "$RACE_BIN" "$RACE_SYNC"
cat > "$RACE_BIN/git" <<'RACE_GIT'
#!/usr/bin/env bash
set -u

wait_for_two() {
  local prefix="$1"
  local count=0
  local attempts=0
  : > "$ORC_RACE_DIR/$prefix.$$"
  while [[ "$attempts" -lt 50 ]]; do
    count="$(find "$ORC_RACE_DIR" -maxdepth 1 -name "$prefix.*" | wc -l | tr -d ' ')"
    [[ "$count" -ge 2 ]] && return 0
    attempts=$((attempts + 1))
    sleep 0.01
  done
}

ARGS=" $* "
if [[ "$ARGS" == *" show-ref --verify --quiet refs/heads/orc-task/"*"/task-race "* ]]; then
  wait_for_two preflight
  "$ORC_RACE_REAL_GIT" "$@"
  exit $?
fi
if [[ "$ARGS" == *" worktree add "* && "$ARGS" == *"/task-race "* ]]; then
  wait_for_two add
  "$ORC_RACE_REAL_GIT" "$@"
  RC=$?
  if [[ "$RC" -eq 0 ]]; then
    ATTEMPTS=0
    while [[ ! -e "$ORC_RACE_DIR/loser" && "$ATTEMPTS" -lt 50 ]]; do
      ATTEMPTS=$((ATTEMPTS + 1))
      sleep 0.01
    done
    sleep 0.2
  else
    : > "$ORC_RACE_DIR/loser"
  fi
  exit "$RC"
fi
exec "$ORC_RACE_REAL_GIT" "$@"
RACE_GIT
chmod +x "$RACE_BIN/git"

PATH="$RACE_BIN:$PATH" ORC_RACE_REAL_GIT="$REAL_GIT" ORC_RACE_DIR="$RACE_SYNC" \
  "$LIFECYCLE" create --control-dir "$RACE_CONTROL" --task-dir "$RACE_TASK_DIR" \
  --mission mission --task-id task-race --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$RACE_CHILD" \
  >"$TMP/race-a.out" 2>"$TMP/race-a.err" &
RACE_PID_A=$!
PATH="$RACE_BIN:$PATH" ORC_RACE_REAL_GIT="$REAL_GIT" ORC_RACE_DIR="$RACE_SYNC" \
  "$LIFECYCLE" create --control-dir "$RACE_CONTROL" --task-dir "$RACE_TASK_DIR" \
  --mission race-b --task-id task-race --repo "$REPO" \
  --parent-worktree "$RACE_PARENT_B" --worktree "$RACE_CHILD" \
  >"$TMP/race-b.out" 2>"$TMP/race-b.err" &
RACE_PID_B=$!
wait "$RACE_PID_A"; RACE_RC_A=$?
wait "$RACE_PID_B"; RACE_RC_B=$?
RACE_SUCCESS_COUNT=0
[[ "$RACE_RC_A" -eq 0 ]] && RACE_SUCCESS_COUNT=$((RACE_SUCCESS_COUNT + 1))
[[ "$RACE_RC_B" -eq 0 ]] && RACE_SUCCESS_COUNT=$((RACE_SUCCESS_COUNT + 1))
RACE_MANIFEST="$RACE_CONTROL/tasks/task-race/worktrees.txt"
RACE_ROW_BRANCH=""
RACE_ROW_BASE=""
if [[ -s "$RACE_MANIFEST" ]]; then
  IFS=$'\t' read -r _ RACE_ROW_BRANCH RACE_ROW_BASE _ _ < "$RACE_MANIFEST"
fi
RACE_ACTUAL_BRANCH="$(git -C "$RACE_CHILD" branch --show-current 2>/dev/null || true)"
RACE_ACTUAL_HEAD="$(git -C "$RACE_CHILD" rev-parse HEAD 2>/dev/null || true)"
if [[ "$RACE_ACTUAL_BRANCH" == "orc-task/mission/task-race" ]]; then
  RACE_LOSER_BRANCH="orc-task/race-b/task-race"
else
  RACE_LOSER_BRANCH="orc-task/mission/task-race"
fi
check "concurrent lifecycle has one winner and loser cannot alter winner" bash -c \
  '[[ "$1" -eq 1 && -d "$2" && -s "$3" && -s "$4" && "$5" = "$6" && "$7" = "$8" && "$9" = "${10}" && ! -e "${11}" ]] && cmp -s "$3" "$4" && [[ ! "$3" -ef "$4" ]] && ! git -C "${12}" show-ref --verify --quiet "refs/heads/${13}"' _ "$RACE_SUCCESS_COUNT" "$RACE_CHILD" "$RACE_MANIFEST" "$RACE_TASK_DIR/worktrees.txt" "$RACE_ROW_BRANCH" "$RACE_ACTUAL_BRANCH" "$RACE_ROW_BASE" "$RACE_ACTUAL_HEAD" "$(awk -F '\t' 'NR == 1 {print $1}' "$RACE_MANIFEST" 2>/dev/null)" "$RACE_CHILD_PHYS" "$RACE_CONTROL/.task-worktree.lock" "$REPO" "$RACE_LOSER_BRANCH"

DUAL_CONTROL="$TMP/dual-recover-hub/control/mission"
DUAL_MISSION="$TMP/dual-recover-hub/missions/mission"
DUAL_TASK="$TMP/dual-recover-task"
DUAL_CHILD="$ALIAS_ROOT/dual-recover-child"
DUAL_LOCK="$DUAL_CONTROL/.task-worktree.lock"
DUAL_GUARD="$DUAL_LOCK.guard"
mkdir -p "$DUAL_CONTROL" "$DUAL_MISSION" "$DUAL_GUARD"
printf 'request\n' > "$DUAL_MISSION/request.md"
printf 'Briefs: brief.md, brief-exec.md\n' > "$DUAL_MISSION/MISSION.md"
printf 'planned\n' > "$DUAL_MISSION/state"
printf 'backend: hybrid\nstage: plan\n' > "$DUAL_MISSION/session.txt"
printf '999996\tdeadguard\n' > "$DUAL_GUARD/owner"
printf '999995\tdeadlock\n' > "$DUAL_LOCK.999995.deadlock"
ln "$DUAL_LOCK.999995.deadlock" "$DUAL_LOCK"
( "$LIFECYCLE" create --control-dir "$DUAL_CONTROL" --task-dir "$DUAL_TASK" \
    --mission mission --task-id task-dual --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$DUAL_CHILD" >/dev/null 2>&1; echo "$?" > "$TMP/dual-a.rc" ) &
DUAL_A=$!
( "$LIFECYCLE" create --control-dir "$DUAL_CONTROL" --task-dir "$DUAL_TASK" \
    --mission mission --task-id task-dual --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$DUAL_CHILD" >/dev/null 2>&1; echo "$?" > "$TMP/dual-b.rc" ) &
DUAL_B=$!
wait "$DUAL_A" 2>/dev/null || true
wait "$DUAL_B" 2>/dev/null || true
DUAL_SUCCESS_COUNT=$(( $(grep -c '^0$' "$TMP/dual-a.rc" 2>/dev/null || true) + $(grep -c '^0$' "$TMP/dual-b.rc" 2>/dev/null || true) ))
check "two stale recoverers serialize to one transition and preserve the live winner" bash -c \
  '[[ "$1" -eq 1 && -d "$2" && -s "$3" && ! -e "$4" && ! -e "$5" ]] && git -C "$6" show-ref --verify --quiet refs/heads/orc-task/mission/task-dual' \
  _ "$DUAL_SUCCESS_COUNT" "$DUAL_CHILD" "$DUAL_CONTROL/tasks/task-dual/worktrees.txt" \
  "$DUAL_LOCK" "$DUAL_GUARD" "$REPO"

OWNERLESS_CONTROL="$TMP/ownerless-hub/control/mission"
OWNERLESS_TASK="$TMP/ownerless-task"
OWNERLESS_CHILD="$ALIAS_ROOT/ownerless-child"
OWNERLESS_GUARD="$OWNERLESS_CONTROL/.task-worktree.lock.guard"
mkdir -p "$OWNERLESS_GUARD"
"$LIFECYCLE" create --control-dir "$OWNERLESS_CONTROL" --task-dir "$OWNERLESS_TASK" \
  --mission mission --task-id task-ownerless --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$OWNERLESS_CHILD" >/dev/null 2>&1
OWNERLESS_RC=$?
check "half-published ownerless guard is transactionally recovered without permanent lockout" bash -c \
  '[[ "$1" -eq 0 && -d "$2" && -s "$3" && ! -e "$4" ]]' \
  _ "$OWNERLESS_RC" "$OWNERLESS_CHILD" \
  "$OWNERLESS_CONTROL/tasks/task-ownerless/worktrees.txt" "$OWNERLESS_GUARD"

RELEASE_CONTROL="$TMP/release-replacement-hub/control/mission"
RELEASE_TASK="$TMP/release-replacement-task"
RELEASE_CHILD="$ALIAS_ROOT/release-replacement-child"
RELEASE_LOCK="$RELEASE_CONTROL/.task-worktree.lock"
mkdir -p "$RELEASE_CONTROL"
sleep 30 &
RELEASE_OWNER_PID=$!
RELEASE_TOKEN=releaselive
RELEASE_CANDIDATE="$RELEASE_LOCK.$RELEASE_OWNER_PID.$RELEASE_TOKEN"
RELEASE_SOURCE="$RELEASE_CONTROL/.release-source"
printf '%s\t%s\n' "$RELEASE_OWNER_PID" "$RELEASE_TOKEN" > "$RELEASE_SOURCE"
ln "$RELEASE_SOURCE" "$RELEASE_CANDIDATE"
RELEASE_MARKER="$TMP/release-replaced"
ORC_STALE_LOCK_TEST_FINAL_REPLACEMENT="$RELEASE_SOURCE" \
  ORC_STALE_LOCK_TEST_MARKER="$RELEASE_MARKER" \
  "$LIFECYCLE" create --control-dir "$RELEASE_CONTROL" --task-dir "$RELEASE_TASK" \
  --mission mission --task-id task-release --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$RELEASE_CHILD" >/dev/null 2>&1
RELEASE_REPLACEMENT_RC=$?
check "post-commit release replacement preserves committed resources and the new live lock" bash -c \
  '[[ "$1" -eq 0 && -d "$2" && -s "$3/tasks/task-release/worktrees.txt" && -s "$4/worktrees.txt" && -f "$5" && -f "$6" && "$5" -ef "$6" && -f "$7" && ! -e "$5.guard" ]]' \
  _ "$RELEASE_REPLACEMENT_RC" "$RELEASE_CHILD" "$RELEASE_CONTROL" "$RELEASE_TASK" \
  "$RELEASE_LOCK" "$RELEASE_CANDIDATE" "$RELEASE_MARKER"
kill "$RELEASE_OWNER_PID" >/dev/null 2>&1 || true
wait "$RELEASE_OWNER_PID" 2>/dev/null || true

REPLACE_CONTROL="$TMP/replacement-hub/control/mission"
REPLACE_TASK_DIR="$TMP/replacement-task"
REPLACE_CHILD="$ALIAS_ROOT/replacement-child"
REPLACE_LOCK="$REPLACE_CONTROL/.task-worktree.lock"
OLD_PID=999998
OLD_TOKEN=oldstale
OLD_CANDIDATE="$REPLACE_LOCK.$OLD_PID.$OLD_TOKEN"
mkdir -p "$REPLACE_CONTROL"
printf '%s\t%s\n' "$OLD_PID" "$OLD_TOKEN" > "$OLD_CANDIDATE"
ln "$OLD_CANDIDATE" "$REPLACE_LOCK"
sleep 30 &
REPLACEMENT_OWNER_PID=$!
REPLACEMENT_TOKEN=newlive
REPLACEMENT_CANDIDATE="$REPLACE_LOCK.$REPLACEMENT_OWNER_PID.$REPLACEMENT_TOKEN"
REPLACEMENT_SOURCE="$REPLACE_CONTROL/.replacement-source"
printf '%s\t%s\n' "$REPLACEMENT_OWNER_PID" "$REPLACEMENT_TOKEN" > "$REPLACEMENT_SOURCE"
ln "$REPLACEMENT_SOURCE" "$REPLACEMENT_CANDIDATE"
REPLACEMENT_MARKER="$TMP/replacement-published"
ORC_STALE_LOCK_TEST_FINAL_REPLACEMENT="$REPLACEMENT_SOURCE" \
  ORC_STALE_LOCK_TEST_MARKER="$REPLACEMENT_MARKER" \
  "$LIFECYCLE" create --control-dir "$REPLACE_CONTROL" --task-dir "$REPLACE_TASK_DIR" \
  --mission mission --task-id task-replacement --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$REPLACE_CHILD" >/dev/null 2>&1
REPLACEMENT_RC=$?
check "stale-lock replacement preserves the newly acquired live owner exactly" bash -c \
  '[[ "$1" -ne 0 && -f "$2" && -f "$3" && "$2" -ef "$3" && -f "$4" && ! -e "$5" && ! -e "$6" && -f "$7" ]]' \
  _ "$REPLACEMENT_RC" "$REPLACE_LOCK" "$REPLACEMENT_CANDIDATE" \
  "$REPLACEMENT_MARKER" "$REPLACE_CHILD" "$REPLACE_CONTROL/tasks/task-replacement" "$OLD_CANDIDATE"
kill "$REPLACEMENT_OWNER_PID" >/dev/null 2>&1 || true
wait "$REPLACEMENT_OWNER_PID" 2>/dev/null || true
rm -f -- "$OLD_CANDIDATE"
"$LIFECYCLE" create --control-dir "$REPLACE_CONTROL" --task-dir "$REPLACE_TASK_DIR" \
  --mission mission --task-id task-replacement --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$REPLACE_CHILD" >/dev/null 2>&1
REPLACEMENT_RETRY_RC=$?
check "stale replacement owner exit permits an exact retry without lock residue" bash -c \
  '[[ "$1" -eq 0 && -d "$2" && ! -e "$3" && ! -e "$4" ]]' \
  _ "$REPLACEMENT_RETRY_RC" "$REPLACE_CHILD" "$REPLACE_LOCK" "$REPLACEMENT_CANDIDATE"

STALE_CONTROL="$TMP/stale-hub/control/mission"
STALE_TASK_DIR="$TMP/stale-task"
STALE_CHILD="$ALIAS_ROOT/stale-child"
STALE_PID=999999
STALE_TOKEN=staleowner
STALE_LOCK="$STALE_CONTROL/.task-worktree.lock"
STALE_CANDIDATE="$STALE_LOCK.$STALE_PID.$STALE_TOKEN"
mkdir -p "$STALE_CONTROL"
printf '%s\t%s\n' "$STALE_PID" "$STALE_TOKEN" > "$STALE_CANDIDATE"
ln "$STALE_CANDIDATE" "$STALE_LOCK"
"$LIFECYCLE" create --control-dir "$STALE_CONTROL" --task-dir "$STALE_TASK_DIR" \
  --mission mission --task-id task-stale --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$STALE_CHILD" >/dev/null 2>&1
STALE_RC=$?
check "verified dead-owner lock is recovered without residual lock" bash -c \
  '[[ "$1" -eq 0 && -d "$2" && -s "$3" && -s "$4" && ! -e "$5" && ! -e "$6" ]]' _ "$STALE_RC" "$STALE_CHILD" "$STALE_CONTROL/tasks/task-stale/worktrees.txt" "$STALE_TASK_DIR/worktrees.txt" "$STALE_LOCK" "$STALE_CANDIDATE"

CREATE_RC=127
if [[ -x "$LIFECYCLE" ]]; then
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null 2>&1
  CREATE_RC=$?
fi

check "child lifecycle script exists and is executable" test -x "$LIFECYCLE"
check "child creation succeeds" test "$CREATE_RC" -eq 0
check "child branch uses orc-task namespace" bash -c \
  '[[ -d "$1" && "$(git -C "$1" branch --show-current)" = "orc-task/mission/task-a" ]]' _ "$CHILD"
check "child starts at the exact parent mission tip" bash -c \
  '[[ -d "$1" && "$(git -C "$1" rev-parse HEAD)" = "$2" ]]' _ "$CHILD" "$PARENT_TIP"
check "coordinator manifest is authoritative and worker copy is separate" bash -c \
  'manifest="$1/tasks/task-a/worktrees.txt"; IFS=$'"'"'\t'"'"' read -r worktree branch base repo extra < "$manifest"; [[ -s "$manifest" && -s "$2/worktrees.txt" && "$worktree" = "$3" && "$branch" = "orc-task/mission/task-a" && "$base" = "$4" && "$repo" = "$5" && -z "$extra" ]] && cmp -s "$manifest" "$2/worktrees.txt" && [[ ! "$manifest" -ef "$2/worktrees.txt" ]]' _ "$CONTROL" "$TASK_DIR" "$CHILD_PHYS" "$PARENT_TIP" "$REPO_PHYS"

DUP_RC=127
TAB_RC=127
NEWLINE_RC=127
OWNER_RC=127
if [[ -x "$LIFECYCLE" ]]; then
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null 2>&1
  DUP_RC=$?
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TMP/tab" \
    --mission mission --task-id $'bad\tid' --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$TMP/tab-child" >/dev/null 2>&1
  TAB_RC=$?
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TMP/newline" \
    --mission mission --task-id $'bad\nid' --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$TMP/newline-child" >/dev/null 2>&1
  NEWLINE_RC=$?
  git -C "$REPO" worktree remove "$CHILD" >/dev/null 2>&1
  "$LIFECYCLE" create --control-dir "$CONTROL" --task-dir "$TMP/task-b" \
    --mission mission --task-id task-b --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" >/dev/null 2>&1
  OWNER_RC=$?
fi
check "duplicate task branch or worktree is refused" bash -c \
  '[[ -x "$1" && "$2" -ne 0 ]]' _ "$LIFECYCLE" "$DUP_RC"
check "tab or newline task identity is refused" bash -c \
  '[[ -x "$1" && "$2" -ne 0 && "$3" -ne 0 ]]' _ "$LIFECYCLE" "$TAB_RC" "$NEWLINE_RC"
check "worktree owned by another active task is refused" bash -c \
  '[[ -x "$1" && "$2" -ne 0 ]]' _ "$LIFECYCLE" "$OWNER_RC"

# Rework may reuse only the exact retained task authority after collection.
REWORK_CONTROL_TASK="$CONTROL/tasks/task-a"
printf 'collected\n' > "$REWORK_CONTROL_TASK/state"
printf 'collected\n' > "$TASK_DIR/state"
printf '01a0task-worktree-thread\n' > "$REWORK_CONTROL_TASK/accepted-thread-id"
printf '01a0task-worktree-thread\n' > "$TASK_DIR/accepted-thread-id"
printf 'unarchived\n' > "$REWORK_CONTROL_TASK/task-window-state"
printf 'updated parent\n' > "$PARENT/rework-parent.txt"
git -C "$PARENT" add rework-parent.txt
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -qm rework-parent
UPDATED_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >/dev/null 2>&1
REWORK_BRANCH_PRESENT_RC=$?
check "reprovision refuses while the old local branch remains" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" ]] && git -C "$3" show-ref --verify --quiet refs/heads/orc-task/mission/task-a' \
  _ "$REWORK_BRANCH_PRESENT_RC" "$CHILD" "$REPO"
git -C "$REPO" update-ref -d refs/heads/orc-task/mission/task-a

"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$TMP/wrong-rework-child" --expected-generation 1 \
  >/dev/null 2>&1
check "reprovision refuses a worktree path different from retained authority" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && ! -e "$3" ]]' \
  _ "$?" "$TMP/wrong-rework-child" "$CHILD"

printf 'archived\n' > "$REWORK_CONTROL_TASK/task-window-state"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >/dev/null 2>&1
check "reprovision requires the exact accepted thread to be unarchived" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" ]]' _ "$?" "$CHILD"

printf 'unarchived\n' > "$REWORK_CONTROL_TASK/task-window-state"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 2 \
  >/dev/null 2>&1
check "reprovision rejects a stale or skipped expected generation" bash -c \
  '[[ "$1" -ne 0 && ! -e "$2" && "$(cat "$3/generation" 2>/dev/null)" = 1 ]]' \
  _ "$?" "$CHILD" "$REWORK_CONTROL_TASK"

REPROVISION_FSYNC_MARKER="$TMP/reprovision-fsync-marker"
ORC_REPROVISION_FSYNC_TEST_MARKER="$REPROVISION_FSYNC_MARKER" \
  ORC_REPROVISION_REQUIRE_FSYNC_TEST_MARKER="$REPROVISION_FSYNC_MARKER" \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 1 \
  >"$TMP/reprovision-final.out" 2>"$TMP/reprovision-final.err"
REPROVISION_RC=$?
if [[ "$REPROVISION_RC" -ne 0 ]]; then
  sed 's/^/  reprovision diagnostic: /' "$TMP/reprovision-final.err"
fi
check "exact collected authority reprovisions generation two from updated parent" bash -c \
  '[[ "$1" -eq 0 && -d "$2" && "$(git -C "$2" rev-parse HEAD)" = "$3" && "$(cat "$4/generation")" = 2 && "$(cat "$5/generation")" = 2 && "$(cat "$4/state")" = ready && "$(cat "$5/state")" = ready && "$(cat "$4/accepted-thread-id")" = "$6" ]] && cmp -s "$4/worktrees.txt" "$5/worktrees.txt" && [[ ! "$4/worktrees.txt" -ef "$5/worktrees.txt" ]]' \
  _ "$REPROVISION_RC" "$CHILD" "$UPDATED_PARENT_TIP" "$REWORK_CONTROL_TASK" "$TASK_DIR" 01a0task-worktree-thread
check "reprovision fsync boundary runs before authority replacement" test -s "$REPROVISION_FSYNC_MARKER"

printf 'collected\n' > "$REWORK_CONTROL_TASK/state"
printf 'collected\n' > "$TASK_DIR/state"
git -C "$REPO" worktree remove "$CHILD" >/dev/null
git -C "$REPO" update-ref -d refs/heads/orc-task/mission/task-a
printf 'second updated parent\n' > "$PARENT/rework-parent-2.txt"
git -C "$PARENT" add rework-parent-2.txt
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -qm rework-parent-2
SECOND_UPDATED_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
ORC_REPROVISION_TEST_FAIL_PUBLISH_AFTER=3 \
  ORC_REPROVISION_TEST_FAIL_RESTORE_AFTER=1 \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 2 \
  >/dev/null 2>&1
PARTIAL_REPROVISION_RC=$?
check "mid-batch publication plus restore failure preserves durable recovery evidence" bash -c \
  '[[ "$1" -ne 0 && -s "$2/reprovision-intent" && -d "$3" ]] && git -C "$4" show-ref --verify --quiet refs/heads/orc-task/mission/task-a && [[ -n "$(find "$2" -maxdepth 1 -name ".reprovision-stage.*" -print -quit)" && -n "$(find "$2" -maxdepth 1 -name ".reprovision-backup.*" -print -quit)" ]]' \
  _ "$PARTIAL_REPROVISION_RC" "$REWORK_CONTROL_TASK" "$CHILD" "$REPO"

ORC_REPROVISION_TEST_FAIL_AFTER_CONVERGE=1 \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 2 \
  >"$TMP/reprovision-reconcile.out" 2>"$TMP/reprovision-reconcile.err"
INTERRUPTED_RECONCILE_RC=$?
if [[ "$INTERRUPTED_RECONCILE_RC" -eq 0 ]]; then
  sed 's/^/  reprovision reconcile diagnostic: /' "$TMP/reprovision-reconcile.err"
fi
check "post-convergence interruption retains intent over exact generation three" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/generation")" = 3 && "$(cat "$3/generation")" = 3 && "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready && -s "$2/reprovision-intent" ]] && cmp -s "$2/worktrees.txt" "$3/worktrees.txt"' \
  _ "$INTERRUPTED_RECONCILE_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR"
for PARTIAL_CLEANUP_DIR in "$REWORK_CONTROL_TASK"/.reprovision-backup.* "$TASK_DIR"/.reprovision-stage.*; do
  [[ -d "$PARTIAL_CLEANUP_DIR" && ! -L "$PARTIAL_CLEANUP_DIR" ]] || continue
  rm -rf "$PARTIAL_CLEANUP_DIR"
done

"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 2 \
  >/dev/null 2>&1
RECONCILE_REPROVISION_RC=$?
check "reprovision retry reconciles partial authority to exact generation three" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 3 && "$(cat "$3/generation")" = 3 && "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready && "$(cat "$2/accepted-thread-id")" = "$4" && "$(git -C "$5" rev-parse HEAD)" = "$6" && ! -e "$2/reprovision-intent" ]] && cmp -s "$2/worktrees.txt" "$3/worktrees.txt" && [[ -z "$(find "$2" -maxdepth 1 \( -name ".reprovision-stage.*" -o -name ".reprovision-backup.*" \) -print -quit)" ]]' \
  _ "$RECONCILE_REPROVISION_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR" 01a0task-worktree-thread "$CHILD" "$SECOND_UPDATED_PARENT_TIP"

printf 'collected\n' > "$REWORK_CONTROL_TASK/state"
printf 'collected\n' > "$TASK_DIR/state"
git -C "$REPO" worktree remove "$CHILD" >/dev/null
git -C "$REPO" update-ref -d refs/heads/orc-task/mission/task-a
printf 'third updated parent\n' > "$PARENT/rework-parent-3.txt"
git -C "$PARENT" add rework-parent-3.txt
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -qm rework-parent-3
THIRD_UPDATED_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
ORC_REPROVISION_TEST_FAIL_AFTER_INTENT_REMOVAL_NORMAL=1 \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
NORMAL_POST_INTENT_RC=$?
check "normal success interruption after intent removal leaves exact generation four" bash -c \
  '[[ "$1" -ne 0 && "$(cat "$2/generation")" = 4 && "$(cat "$3/generation")" = 4 && "$(cat "$2/state")" = ready && "$(cat "$3/state")" = ready && ! -e "$2/reprovision-intent" && -s "$2/reprovision-completion.json" && "$(git -C "$4" rev-parse HEAD)" = "$5" ]] && cmp -s "$2/worktrees.txt" "$3/worktrees.txt"' \
  _ "$NORMAL_POST_INTENT_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR" "$CHILD" "$THIRD_UPDATED_PARENT_TIP"

printf 'unrelated-thread\n' > "$REWORK_CONTROL_TASK/accepted-thread-id"
printf 'unrelated-thread\n' > "$TASK_DIR/accepted-thread-id"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion receipt rejects both-side accepted-thread mutation" test "$?" -ne 0
printf '01a0task-worktree-thread\n' > "$REWORK_CONTROL_TASK/accepted-thread-id"
printf '01a0task-worktree-thread\n' > "$TASK_DIR/accepted-thread-id"

cp "$REWORK_CONTROL_TASK/worktrees.txt" "$TMP/receipt-control-manifest"
cp "$TASK_DIR/worktrees.txt" "$TMP/receipt-worker-manifest"
printf '\n' >> "$REWORK_CONTROL_TASK/worktrees.txt"
printf '\n' >> "$TASK_DIR/worktrees.txt"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion receipt rejects extra blank manifest lines on both sides" test "$?" -ne 0
cp "$TMP/receipt-control-manifest" "$REWORK_CONTROL_TASK/worktrees.txt"
cp "$TMP/receipt-worker-manifest" "$TASK_DIR/worktrees.txt"

printf 'dirty completion\n' > "$CHILD/receipt-dirty.txt"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion receipt rejects a dirty worktree" test "$?" -ne 0
rm -f "$CHILD/receipt-dirty.txt"

RECEIPT_BRANCH_TIP="$(git -C "$REPO" rev-parse "refs/heads/orc-task/mission/task-a")"
RECEIPT_MUTATED_TIP="$(printf 'receipt branch mutation\n' | git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "${RECEIPT_BRANCH_TIP}^{tree}")" -p "$RECEIPT_BRANCH_TIP")"
git -C "$REPO" update-ref refs/heads/orc-task/mission/task-a "$RECEIPT_MUTATED_TIP" "$RECEIPT_BRANCH_TIP"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion receipt rejects branch and worktree tip mutation" test "$?" -ne 0
git -C "$REPO" update-ref refs/heads/orc-task/mission/task-a "$RECEIPT_BRANCH_TIP" "$RECEIPT_MUTATED_TIP"

printf 'blocked\n' > "$TASK_DIR/state"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion receipt rejects one-sided worker authority mutation" test "$?" -ne 0
printf 'ready\n' > "$TASK_DIR/state"

RECEIPT_PATH="$REWORK_CONTROL_TASK/reprovision-completion.json"
RECEIPT_BACKUP="$TMP/reprovision-completion.json"
RECEIPT_WAS_PRESENT=0
if [[ -f "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]]; then
  cp "$RECEIPT_PATH" "$RECEIPT_BACKUP"
  RECEIPT_WAS_PRESENT=1
  rm -f "$RECEIPT_PATH"
fi
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
check "completion inference fails closed when the exact receipt is absent" test "$?" -ne 0
if [[ "$RECEIPT_WAS_PRESENT" -eq 1 ]]; then
  cp "$RECEIPT_BACKUP" "$RECEIPT_PATH"
fi

if [[ "$RECEIPT_WAS_PRESENT" -eq 1 ]]; then
  rm -f "$RECEIPT_PATH"
  ln -s "$RECEIPT_BACKUP" "$RECEIPT_PATH"
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
    >/dev/null 2>&1
  RECEIPT_SYMLINK_RC=$?
  rm -f "$RECEIPT_PATH"
  cp "$RECEIPT_BACKUP" "$RECEIPT_PATH"
else
  RECEIPT_SYMLINK_RC=0
fi
check "completion receipt symlink is refused" test "$RECEIPT_SYMLINK_RC" -ne 0

if [[ "$RECEIPT_WAS_PRESENT" -eq 1 ]]; then
  printf '{"invalid":true}\n' > "$RECEIPT_PATH"
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
    --mission mission --task-id task-a --repo "$REPO" \
    --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
    >/dev/null 2>&1
  RECEIPT_FORMAT_RC=$?
  cp "$RECEIPT_BACKUP" "$RECEIPT_PATH"
else
  RECEIPT_FORMAT_RC=0
fi
check "malformed completion receipt is refused" test "$RECEIPT_FORMAT_RC" -ne 0

"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 3 \
  >/dev/null 2>&1
NORMAL_COMPLETION_RETRY_RC=$?
check "exact retry recognizes already-completed normal generation four" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 4 && "$(cat "$3/generation")" = 4 && -d "$4" && "$(git -C "$4" rev-parse HEAD)" = "$5" ]]' \
  _ "$NORMAL_COMPLETION_RETRY_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR" "$CHILD" "$THIRD_UPDATED_PARENT_TIP"

printf 'collected\n' > "$REWORK_CONTROL_TASK/state"
printf 'collected\n' > "$TASK_DIR/state"
git -C "$REPO" worktree remove "$CHILD" >/dev/null
git -C "$REPO" update-ref -d refs/heads/orc-task/mission/task-a
printf 'fourth updated parent\n' > "$PARENT/rework-parent-4.txt"
git -C "$PARENT" add rework-parent-4.txt
git -C "$PARENT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
  commit -qm rework-parent-4
FOURTH_UPDATED_PARENT_TIP="$(git -C "$PARENT" rev-parse HEAD)"
ORC_REPROVISION_TEST_FAIL_PUBLISH_AFTER=3 \
  ORC_REPROVISION_TEST_FAIL_RESTORE_AFTER=1 \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 4 \
  >/dev/null 2>&1
RECOVERY_WINDOW_PREP_RC=$?
ORC_REPROVISION_TEST_FAIL_AFTER_INTENT_REMOVAL_RECOVERY=1 \
  "$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 4 \
  >/dev/null 2>&1
RECOVERY_POST_INTENT_RC=$?
check "recovery success interruption after intent removal leaves exact generation five" bash -c \
  '[[ "$1" -ne 0 && "$2" -ne 0 && "$(cat "$3/generation")" = 5 && "$(cat "$4/generation")" = 5 && ! -e "$3/reprovision-intent" && -s "$3/reprovision-completion.json" && "$(cat "$3/state")" = ready && "$(cat "$4/state")" = ready && "$(git -C "$5" rev-parse HEAD)" = "$6" ]] && cmp -s "$3/worktrees.txt" "$4/worktrees.txt"' \
  _ "$RECOVERY_WINDOW_PREP_RC" "$RECOVERY_POST_INTENT_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR" "$CHILD" "$FOURTH_UPDATED_PARENT_TIP"
"$LIFECYCLE" reprovision --control-dir "$CONTROL" --task-dir "$TASK_DIR" \
  --mission mission --task-id task-a --repo "$REPO" \
  --parent-worktree "$PARENT" --worktree "$CHILD" --expected-generation 4 \
  >/dev/null 2>&1
RECOVERY_COMPLETION_RETRY_RC=$?
check "exact retry recognizes already-completed recovery generation five" bash -c \
  '[[ "$1" -eq 0 && "$(cat "$2/generation")" = 5 && "$(cat "$3/generation")" = 5 && -d "$4" && "$(git -C "$4" rev-parse HEAD)" = "$5" ]]' \
  _ "$RECOVERY_COMPLETION_RETRY_RC" "$REWORK_CONTROL_TASK" "$TASK_DIR" "$CHILD" "$FOURTH_UPDATED_PARENT_TIP"

echo "  child-worktree-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
