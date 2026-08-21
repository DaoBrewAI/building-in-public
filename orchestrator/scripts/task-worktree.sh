#!/usr/bin/env bash
# Create one coordinator-owned branch/worktree pair for an approved child task.

set -euo pipefail

LOCK_FILE=""
LOCK_CANDIDATE=""
LOCK_TOKEN=""
LOCK_OWNED=0
LOCK_CANDIDATE_OWNED=0
LOCK_PUBLISH_INTENT=0

usage() {
  echo "usage: task-worktree.sh create --control-dir <dir> --task-dir <dir> --mission <slug> --task-id <id> --repo <repo> --parent-worktree <dir> --worktree <dir>" >&2
}

fail() {
  echo "task-worktree: $1" >&2
  exit 1
}

valid_identity() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

absolute_path() {
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

physical_path() {
  local probe="$1"
  local suffix=""
  local leaf
  while [[ ! -e "$probe" && ! -L "$probe" ]]; do
    [[ "$probe" != "/" ]] || return 1
    leaf="$(basename "$probe")"
    suffix="/$leaf$suffix"
    probe="$(dirname "$probe")"
  done
  [[ -d "$probe" ]] || return 1
  printf '%s%s\n' "$(cd "$probe" && pwd -P)" "$suffix"
}

paths_overlap() {
  local left="$1"
  local right="$2"
  [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

release_lock() {
  local release_ok=1
  if [[ "$LOCK_PUBLISH_INTENT" -eq 1 ]]; then
    if [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" && -f "$LOCK_CANDIDATE" && ! -L "$LOCK_CANDIDATE" && "$LOCK_FILE" -ef "$LOCK_CANDIDATE" ]]; then
      if ! rm -f -- "$LOCK_FILE"; then
        echo "task-worktree: coordinator lock release failed" >&2
        release_ok=0
      else
        LOCK_OWNED=0
        LOCK_PUBLISH_INTENT=0
      fi
    elif [[ "$LOCK_OWNED" -eq 1 ]]; then
      echo "task-worktree: coordinator lock ownership changed; lock preserved" >&2
      release_ok=0
    else
      LOCK_PUBLISH_INTENT=0
    fi
  fi
  if [[ "$LOCK_CANDIDATE_OWNED" -eq 1 && "$LOCK_OWNED" -eq 0 && "$LOCK_PUBLISH_INTENT" -eq 0 ]]; then
    rm -f -- "$LOCK_CANDIDATE"
    LOCK_CANDIDATE_OWNED=0
  fi
  [[ "$release_ok" -eq 1 ]]
}

pid_is_live() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'
}

acquire_lock() {
  local stale_pid=""
  local stale_token=""
  local stale_extra=""
  local stale_candidate=""
  local candidate_pid=""
  local candidate_token=""
  local candidate_extra=""

  LOCK_TOKEN="$RANDOM.$(date +%s)"
  LOCK_CANDIDATE="$LOCK_FILE.$$.$LOCK_TOKEN"
  [[ ! -e "$LOCK_CANDIDATE" && ! -L "$LOCK_CANDIDATE" ]] || fail "coordinator lock candidate already exists"
  if ! (umask 077 && printf '%s\t%s\n' "$$" "$LOCK_TOKEN" > "$LOCK_CANDIDATE"); then
    fail "cannot create coordinator lock candidate"
  fi
  LOCK_CANDIDATE_OWNED=1

  LOCK_PUBLISH_INTENT=1
  if ln "$LOCK_CANDIDATE" "$LOCK_FILE" 2>/dev/null; then
    [[ "$LOCK_FILE" -ef "$LOCK_CANDIDATE" ]] || fail "coordinator lock publication could not be verified"
    LOCK_OWNED=1
    return 0
  fi

  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || fail "coordinator mutation lock is unsafe or busy"
  IFS=$'\t' read -r stale_pid stale_token stale_extra < "$LOCK_FILE" || fail "coordinator mutation lock is malformed"
  case "$stale_pid" in
    ''|*[!0-9]*) fail "coordinator mutation lock has an invalid owner" ;;
  esac
  valid_identity "$stale_token" || fail "coordinator mutation lock has an invalid token"
  [[ -z "$stale_extra" ]] || fail "coordinator mutation lock is malformed"
  pid_is_live "$stale_pid" && fail "coordinator mutation lock is busy"

  stale_candidate="$LOCK_FILE.$stale_pid.$stale_token"
  [[ -f "$stale_candidate" && ! -L "$stale_candidate" && "$LOCK_FILE" -ef "$stale_candidate" ]] || fail "stale coordinator lock ownership cannot be verified"
  IFS=$'\t' read -r candidate_pid candidate_token candidate_extra < "$stale_candidate" || fail "stale coordinator lock candidate is malformed"
  [[ "$candidate_pid" == "$stale_pid" && "$candidate_token" == "$stale_token" && -z "$candidate_extra" ]] || fail "stale coordinator lock candidate does not match"
  pid_is_live "$stale_pid" && fail "coordinator mutation lock became active"
  [[ "$LOCK_FILE" -ef "$stale_candidate" ]] || fail "stale coordinator lock changed during reconciliation"
  rm -f -- "$LOCK_FILE"
  rm -f -- "$stale_candidate"

  LOCK_PUBLISH_INTENT=1
  if ! ln "$LOCK_CANDIDATE" "$LOCK_FILE" 2>/dev/null; then
    fail "coordinator mutation lock contention persisted"
  fi
  [[ "$LOCK_FILE" -ef "$LOCK_CANDIDATE" ]] || fail "coordinator lock publication could not be verified"
  LOCK_OWNED=1
}

lock_exit() {
  local original_rc="$1"
  trap - EXIT HUP INT TERM
  release_lock || true
  exit "$original_rc"
}

[[ "${1:-}" == "create" ]] || { usage; exit 1; }
shift

CONTROL_DIR=""
TASK_DIR=""
MISSION=""
TASK_ID=""
REPO=""
PARENT_WORKTREE=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; CONTROL_DIR="$2"; shift 2 ;;
    --task-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_DIR="$2"; shift 2 ;;
    --mission) [[ $# -ge 2 ]] || { usage; exit 1; }; MISSION="$2"; shift 2 ;;
    --task-id) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_ID="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { usage; exit 1; }; REPO="$2"; shift 2 ;;
    --parent-worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; PARENT_WORKTREE="$2"; shift 2 ;;
    --worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; WORKTREE="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

for VALUE in "$CONTROL_DIR" "$TASK_DIR" "$MISSION" "$TASK_ID" "$REPO" "$PARENT_WORKTREE" "$WORKTREE"; do
  [[ -n "$VALUE" ]] || { usage; exit 1; }
done
valid_identity "$MISSION" || fail "invalid mission identity"
valid_identity "$TASK_ID" || fail "invalid task identity"

for PATH_VALUE in "$CONTROL_DIR" "$TASK_DIR" "$REPO" "$PARENT_WORKTREE" "$WORKTREE"; do
  absolute_path "$PATH_VALUE" || fail "paths must be absolute"
  case "$PATH_VALUE" in
    *$'\t'*|*$'\n'*|*$'\r'*) fail "paths may not contain tabs or newlines" ;;
    */./*|*/../*|*/.|*/..) fail "paths may not contain dot components" ;;
  esac
done

[[ -d "$CONTROL_DIR" && ! -L "$CONTROL_DIR" ]] || fail "control directory missing or symlinked: $CONTROL_DIR"
[[ -d "$REPO" && ! -L "$REPO" ]] || fail "repository missing or symlinked: $REPO"
[[ -d "$PARENT_WORKTREE" && ! -L "$PARENT_WORKTREE" ]] || fail "parent worktree missing or symlinked: $PARENT_WORKTREE"
[[ ! -e "$WORKTREE" && ! -L "$WORKTREE" ]] || fail "child worktree already exists: $WORKTREE"
[[ -d "$(dirname "$WORKTREE")" ]] || fail "child worktree parent directory missing: $(dirname "$WORKTREE")"
[[ ! -L "$TASK_DIR" ]] || fail "task directory is symlinked: $TASK_DIR"
[[ ! -e "$TASK_DIR" || -d "$TASK_DIR" ]] || fail "task path is not a directory: $TASK_DIR"

REPO_COMMON="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "not a Git repository: $REPO"
PARENT_COMMON="$(cd "$PARENT_WORKTREE" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "not a Git worktree: $PARENT_WORKTREE"
[[ "$REPO_COMMON" == "$PARENT_COMMON" ]] || fail "parent worktree belongs to another repository"

PARENT_BRANCH="$(git -C "$PARENT_WORKTREE" symbolic-ref --quiet --short HEAD)" || fail "parent worktree is detached"
[[ "$PARENT_BRANCH" == "orc/$MISSION" ]] || fail "parent worktree is not on orc/$MISSION"
PARENT_TIP="$(git -C "$PARENT_WORKTREE" rev-parse --verify 'HEAD^{commit}')" || fail "cannot resolve parent tip"
BRANCH="orc-task/$MISSION/$TASK_ID"
git -C "$REPO" check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 || fail "invalid child branch"

PARENT_PHYS="$(physical_path "$PARENT_WORKTREE")" || fail "cannot canonicalize parent worktree"
WORKTREE_PHYS="$(physical_path "$WORKTREE")" || fail "cannot canonicalize child worktree"
TASK_PHYS="$(physical_path "$TASK_DIR")" || fail "cannot canonicalize task directory"
REPO_PHYS="$(physical_path "$REPO")" || fail "cannot canonicalize repository"
CONTROL_PHYS="$(cd "$CONTROL_DIR" && pwd -P)"
paths_overlap "$CONTROL_PHYS" "$PARENT_PHYS" && fail "coordinator control overlaps the parent worktree"
paths_overlap "$CONTROL_PHYS" "$WORKTREE_PHYS" && fail "coordinator control overlaps the child worktree"
paths_overlap "$CONTROL_PHYS" "$TASK_PHYS" && fail "coordinator control overlaps the task directory"
paths_overlap "$CONTROL_PHYS" "$REPO_PHYS" && fail "coordinator control overlaps the repository worktree"
while IFS= read -r LOCK_CHECK_WORKTREE; do
  [[ -n "$LOCK_CHECK_WORKTREE" ]] || continue
  LOCK_CHECK_WORKTREE_PHYS="$(physical_path "$LOCK_CHECK_WORKTREE")" || fail "cannot canonicalize registered Git worktree: $LOCK_CHECK_WORKTREE"
  paths_overlap "$CONTROL_PHYS" "$LOCK_CHECK_WORKTREE_PHYS" && fail "coordinator control overlaps a registered Git worktree"
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')

LOCK_FILE="$CONTROL_PHYS/.task-worktree.lock"
trap 'lock_exit "$?"' EXIT
trap 'exit 1' HUP INT TERM
acquire_lock

CONTROL_TASKS_DIR="$CONTROL_PHYS/tasks"
CONTROL_TASK_DIR="$CONTROL_TASKS_DIR/$TASK_ID"
CONTROL_MANIFEST="$CONTROL_TASK_DIR/worktrees.txt"
MANIFEST_TMP="$CONTROL_MANIFEST.$$"
WORKER_MANIFEST="$TASK_PHYS/worktrees.txt"
WORKER_MANIFEST_TMP="$TASK_PHYS/.worktrees.txt.$$"

[[ ! -L "$CONTROL_TASKS_DIR" ]] || fail "coordinator tasks directory is symlinked"
[[ ! -e "$CONTROL_TASKS_DIR" || -d "$CONTROL_TASKS_DIR" ]] || fail "coordinator tasks path is not a directory"
for CONTROL_TASK_PATH in "$CONTROL_TASKS_DIR"/*; do
  [[ -e "$CONTROL_TASK_PATH" || -L "$CONTROL_TASK_PATH" ]] || continue
  [[ ! -L "$CONTROL_TASK_PATH" ]] || fail "coordinator task path is symlinked: $CONTROL_TASK_PATH"
done
[[ ! -L "$CONTROL_TASK_DIR" ]] || fail "coordinator task directory is symlinked"
[[ ! -e "$CONTROL_TASK_DIR" || -d "$CONTROL_TASK_DIR" ]] || fail "coordinator task path is not a directory"
[[ ! -L "$CONTROL_MANIFEST" ]] || fail "coordinator manifest is symlinked"
[[ ! -e "$MANIFEST_TMP" && ! -L "$MANIFEST_TMP" ]] || fail "coordinator manifest temporary path already exists"
[[ ! -e "$WORKER_MANIFEST_TMP" && ! -L "$WORKER_MANIFEST_TMP" ]] || fail "worker manifest temporary path already exists"
CONTROL_MANIFEST_PHYS="$(physical_path "$CONTROL_MANIFEST")" || fail "cannot canonicalize coordinator manifest"

paths_overlap "$WORKTREE_PHYS" "$TASK_PHYS" && fail "child worktree and task directory overlap"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$PARENT_PHYS" && fail "coordinator manifest overlaps the parent worktree"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$WORKTREE_PHYS" && fail "coordinator manifest overlaps the child worktree"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$TASK_PHYS" && fail "coordinator manifest overlaps the task directory"

while IFS= read -r GIT_WORKTREE; do
  [[ -n "$GIT_WORKTREE" ]] || continue
  GIT_WORKTREE_PHYS="$(physical_path "$GIT_WORKTREE")" || fail "cannot canonicalize registered Git worktree: $GIT_WORKTREE"
  paths_overlap "$WORKTREE_PHYS" "$GIT_WORKTREE_PHYS" && fail "child worktree overlaps a registered Git worktree"
  paths_overlap "$TASK_PHYS" "$GIT_WORKTREE_PHYS" && fail "task directory overlaps a registered Git worktree"
  paths_overlap "$CONTROL_MANIFEST_PHYS" "$GIT_WORKTREE_PHYS" && fail "coordinator manifest overlaps a registered Git worktree"
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')

[[ ! -e "$CONTROL_MANIFEST" ]] || fail "task already has a coordinator manifest: $TASK_ID"
[[ ! -e "$WORKER_MANIFEST" && ! -L "$WORKER_MANIFEST" ]] || fail "task already has a worker manifest: $TASK_ID"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && fail "child branch already exists: $BRANCH"

for MANIFEST in "$CONTROL_PHYS"/tasks/*/worktrees.txt; do
  [[ ! -L "$MANIFEST" ]] || fail "coordinator manifest is symlinked: $MANIFEST"
  [[ -f "$MANIFEST" ]] || continue
  while IFS=$'\t' read -r ROW_WORKTREE ROW_BRANCH ROW_BASE ROW_REPO ROW_EXTRA || [[ -n "${ROW_WORKTREE:-}" ]]; do
    [[ -n "$ROW_WORKTREE" && -n "$ROW_BRANCH" && -n "$ROW_BASE" && -n "$ROW_REPO" && -z "${ROW_EXTRA:-}" ]] || fail "malformed coordinator task manifest: $MANIFEST"
    ROW_WORKTREE_PHYS="$(physical_path "$ROW_WORKTREE")" || fail "invalid coordinator worktree path: $ROW_WORKTREE"
    if paths_overlap "$WORKTREE_PHYS" "$ROW_WORKTREE_PHYS" || \
      paths_overlap "$TASK_PHYS" "$ROW_WORKTREE_PHYS" || \
      paths_overlap "$PARENT_PHYS" "$ROW_WORKTREE_PHYS" || \
      [[ "$ROW_BRANCH" == "$BRANCH" ]]; then
      fail "branch or worktree is already owned by another task"
    fi
    paths_overlap "$CONTROL_MANIFEST_PHYS" "$ROW_WORKTREE_PHYS" && fail "coordinator manifest overlaps a registered task worktree"
  done < "$MANIFEST"
done

CONTROL_TASKS_EXISTED=0
CONTROL_TASK_DIR_EXISTED=0
TASK_DIR_EXISTED=0
[[ -d "$CONTROL_TASKS_DIR" ]] && CONTROL_TASKS_EXISTED=1
[[ -d "$CONTROL_TASK_DIR" ]] && CONTROL_TASK_DIR_EXISTED=1
[[ -d "$TASK_PHYS" ]] && TASK_DIR_EXISTED=1
WORKTREE_CREATE_INTENT=0
WORKTREE_ADDED=0
MANIFEST_TMP_OWNED=0
CONTROL_MANIFEST_PUBLISH_INTENT=0
WORKER_MANIFEST_TMP_OWNED=0
WORKER_MANIFEST_PUBLISH_INTENT=0

rollback() {
  local original_rc="$1"
  local git_cleanup_ok=1
  local manifest_cleanup_ok=1
  local branch_tip=""
  local child_common=""
  local registered_child=0
  trap - EXIT
  trap '' HUP INT TERM

  if [[ "$WORKTREE_CREATE_INTENT" -eq 1 ]]; then
    if git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxq "worktree $WORKTREE_PHYS"; then
      registered_child=1
    fi
    branch_tip="$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)"
    if [[ -d "$WORKTREE_PHYS" ]]; then
      child_common="$(cd "$WORKTREE_PHYS" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
      if [[ "$registered_child" -ne 1 || "$child_common" != "$REPO_COMMON" ]] || \
        [[ "$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" != "$BRANCH" ]] || \
        [[ "$(git -C "$WORKTREE_PHYS" rev-parse --verify HEAD 2>/dev/null || true)" != "$PARENT_TIP" ]] || \
        [[ "$branch_tip" != "$PARENT_TIP" ]] || \
        [[ -n "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
        echo "task-worktree: rollback refused because the created child resource changed" >&2
        git_cleanup_ok=0
      elif ! git -C "$REPO_PHYS" worktree remove --force "$WORKTREE_PHYS" >/dev/null 2>&1; then
        echo "task-worktree: rollback could not remove child worktree: $WORKTREE_PHYS" >&2
        git_cleanup_ok=0
      else
        branch_tip="$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)"
        if [[ -n "$branch_tip" && "$branch_tip" != "$PARENT_TIP" ]]; then
          echo "task-worktree: rollback preserved changed child branch: $BRANCH" >&2
          git_cleanup_ok=0
        elif [[ -n "$branch_tip" ]] && ! git -C "$REPO_PHYS" branch -D "$BRANCH" >/dev/null 2>&1; then
          echo "task-worktree: rollback could not remove child branch: $BRANCH" >&2
          git_cleanup_ok=0
        fi
      fi
    elif [[ "$registered_child" -eq 1 ]]; then
      echo "task-worktree: rollback preserved registered child with a missing worktree path" >&2
      git_cleanup_ok=0
    elif [[ -n "$branch_tip" && "$branch_tip" != "$PARENT_TIP" ]]; then
      echo "task-worktree: rollback preserved changed child branch: $BRANCH" >&2
      git_cleanup_ok=0
    elif [[ -n "$branch_tip" ]] && ! git -C "$REPO_PHYS" branch -D "$BRANCH" >/dev/null 2>&1; then
      echo "task-worktree: rollback could not remove child branch: $BRANCH" >&2
      git_cleanup_ok=0
    elif [[ -e "$WORKTREE_PHYS" || -L "$WORKTREE_PHYS" ]]; then
      echo "task-worktree: rollback preserved unverified child path: $WORKTREE_PHYS" >&2
      git_cleanup_ok=0
    fi
  elif [[ "$WORKTREE_ADDED" -eq 1 ]]; then
    echo "task-worktree: rollback state is inconsistent for the created child resource" >&2
    git_cleanup_ok=0
  fi

  manifest_cleanup_ok="$git_cleanup_ok"
  if [[ "$git_cleanup_ok" -eq 1 ]]; then
    if [[ "$WORKER_MANIFEST_PUBLISH_INTENT" -eq 1 ]]; then
      if [[ -f "$WORKER_MANIFEST" && ! -L "$WORKER_MANIFEST" && -f "$WORKER_MANIFEST_TMP" && ! -L "$WORKER_MANIFEST_TMP" && "$WORKER_MANIFEST" -ef "$WORKER_MANIFEST_TMP" ]]; then
        rm -f -- "$WORKER_MANIFEST"
        WORKER_MANIFEST_PUBLISH_INTENT=0
      elif [[ -e "$WORKER_MANIFEST" || -L "$WORKER_MANIFEST" ]]; then
        echo "task-worktree: rollback preserved worker manifest because ownership changed" >&2
        manifest_cleanup_ok=0
      else
        WORKER_MANIFEST_PUBLISH_INTENT=0
      fi
    fi
    if [[ "$CONTROL_MANIFEST_PUBLISH_INTENT" -eq 1 ]]; then
      if [[ -f "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" && -f "$MANIFEST_TMP" && ! -L "$MANIFEST_TMP" && "$CONTROL_MANIFEST" -ef "$MANIFEST_TMP" ]]; then
        rm -f -- "$CONTROL_MANIFEST"
        CONTROL_MANIFEST_PUBLISH_INTENT=0
      elif [[ -e "$CONTROL_MANIFEST" || -L "$CONTROL_MANIFEST" ]]; then
        echo "task-worktree: rollback preserved coordinator manifest because ownership changed" >&2
        manifest_cleanup_ok=0
      else
        CONTROL_MANIFEST_PUBLISH_INTENT=0
      fi
    fi
  fi
  if [[ "$WORKER_MANIFEST_TMP_OWNED" -eq 1 ]]; then
    rm -f -- "$WORKER_MANIFEST_TMP"
  fi
  if [[ "$MANIFEST_TMP_OWNED" -eq 1 ]]; then
    rm -f -- "$MANIFEST_TMP"
  fi
  if [[ "$manifest_cleanup_ok" -eq 1 ]]; then
    if [[ "$TASK_DIR_EXISTED" -eq 0 ]]; then
      rmdir "$TASK_PHYS" 2>/dev/null || true
    fi
    if [[ "$CONTROL_TASK_DIR_EXISTED" -eq 0 ]]; then
      rmdir "$CONTROL_TASK_DIR" 2>/dev/null || true
    fi
    if [[ "$CONTROL_TASKS_EXISTED" -eq 0 ]]; then
      rmdir "$CONTROL_TASKS_DIR" 2>/dev/null || true
    fi
  fi
  release_lock || true
  exit "$original_rc"
}

trap 'rollback "$?"' EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$CONTROL_TASK_DIR" "$TASK_DIR"
WORKTREE_CREATE_INTENT=1
git -C "$REPO" worktree add -q -b "$BRANCH" "$WORKTREE_PHYS" "$PARENT_TIP"
WORKTREE_ADDED=1

if [[ "${ORC_TASK_WORKTREE_TEST_FAIL_AFTER_ADD:-}" == "1" ]]; then
  fail "injected failure after child worktree creation"
fi

umask 077
MANIFEST_TMP_OWNED=1
printf '%s\t%s\t%s\t%s\n' "$WORKTREE_PHYS" "$BRANCH" "$PARENT_TIP" "$REPO_PHYS" > "$MANIFEST_TMP"
CONTROL_MANIFEST_PUBLISH_INTENT=1
if ! ln "$MANIFEST_TMP" "$CONTROL_MANIFEST" 2>/dev/null; then
  fail "coordinator manifest appeared during publication"
fi
[[ "$CONTROL_MANIFEST" -ef "$MANIFEST_TMP" ]] || fail "coordinator manifest ownership could not be verified"

WORKER_MANIFEST_TMP_OWNED=1
cp "$CONTROL_MANIFEST" "$WORKER_MANIFEST_TMP"
WORKER_MANIFEST_PUBLISH_INTENT=1
if ! ln "$WORKER_MANIFEST_TMP" "$WORKER_MANIFEST" 2>/dev/null; then
  fail "worker manifest appeared during publication"
fi
[[ "$WORKER_MANIFEST" -ef "$WORKER_MANIFEST_TMP" ]] || fail "worker manifest ownership could not be verified"
[[ ! "$CONTROL_MANIFEST" -ef "$WORKER_MANIFEST" ]] || fail "worker manifest must be a copy, not a hard link"

trap 'lock_exit "$?"' EXIT
rm -f -- "$WORKER_MANIFEST_TMP"
WORKER_MANIFEST_TMP_OWNED=0
rm -f -- "$MANIFEST_TMP"
MANIFEST_TMP_OWNED=0
release_lock || fail "could not release coordinator mutation lock"
trap - EXIT HUP INT TERM
echo "created $BRANCH at $PARENT_TIP in $WORKTREE_PHYS"
