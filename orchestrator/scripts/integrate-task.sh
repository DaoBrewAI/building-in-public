#!/usr/bin/env bash
# Verify and integrate one manifest-recorded child task without rewriting history.
set -euo pipefail

usage() {
  echo "usage: integrate-task.sh --control-dir <dir> --task-dir <dir> --mission <slug> --task-id <id> --parent-worktree <dir> --expected-parent-tip <sha>" >&2
}

fail() {
  echo "integrate-task: $1" >&2
  exit 1
}

valid_identity() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

physical_existing_dir() {
  [[ -d "$1" && ! -L "$1" ]] || return 1
  (cd "$1" && pwd -P)
}

read_single_value() {
  local path="$1" value extra
  [[ -f "$path" && ! -L "$path" ]] || return 1
  IFS= read -r value < "$path" || [[ -n "${value:-}" ]] || return 1
  IFS= read -r extra < <(sed -n '2p' "$path") || true
  [[ -n "$value" && -z "${extra:-}" ]] || return 1
  printf '%s\n' "$value"
}

write_value() {
  local path="$1" value="$2" tmp
  tmp="$(mktemp "$(dirname "$path")/.${path##*/}.XXXXXX")" || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! python3 - "$tmp" "$path" <<'PY'
import os
import stat
import sys

source, destination = sys.argv[1:]
source_stat = os.lstat(source)
if not stat.S_ISREG(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
    raise SystemExit(1)
with open(source, "rb") as handle:
    os.fsync(handle.fileno())
try:
    destination_stat = os.lstat(destination)
except FileNotFoundError:
    try:
        os.link(source, destination)
    except FileExistsError:
        raise SystemExit(1)
    published = os.lstat(destination)
    if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or
            (published.st_dev, published.st_ino) != (source_stat.st_dev, source_stat.st_ino)):
        raise SystemExit(1)
    os.unlink(source)
else:
    if not stat.S_ISREG(destination_stat.st_mode) or stat.S_ISLNK(destination_stat.st_mode):
        raise SystemExit(1)
    target = os.environ.get("ORC_ATOMIC_REPLACE_TEST_TARGET")
    marker = os.environ.get("ORC_ATOMIC_REPLACE_TEST_MARKER")
    canonical_destination = os.path.join(os.path.realpath(os.path.dirname(destination) or "."), os.path.basename(destination))
    canonical_target = (os.path.join(os.path.realpath(os.path.dirname(target) or "."), os.path.basename(target))
                        if target else None)
    if (target and canonical_destination == canonical_target and
            (not marker or not os.path.exists(marker))):
        mode = os.environ.get("ORC_ATOMIC_REPLACE_TEST_MODE")
        os.unlink(destination)
        if mode == "symlink":
            os.symlink(os.environ["ORC_ATOMIC_REPLACE_TEST_LINK_TARGET"], destination)
        elif mode == "directory":
            os.mkdir(destination)
        else:
            raise SystemExit(1)
        if marker:
            with open(marker, "w", encoding="utf-8") as handle:
                handle.write("triggered\n")
    current = os.lstat(destination)
    if (not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode) or
            (current.st_dev, current.st_ino) != (destination_stat.st_dev, destination_stat.st_ino)):
        raise SystemExit(1)
    os.replace(source, destination)
    published = os.lstat(destination)
    if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or
            (published.st_dev, published.st_ino) != (source_stat.st_dev, source_stat.st_ino)):
        raise SystemExit(1)
directory = os.path.dirname(destination) or "."
descriptor = os.open(directory, os.O_RDONLY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  then
    rm -f -- "$tmp"
    return 1
  fi
}

acquire_integration_lock() {
  local control="$1" candidate rc
  LOCK_FILE="$control/.task-integration.lock"
  if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
    candidate="$(mktemp "$control/.task-integration.lockfile.XXXXXX")" || return 1
    chmod 0400 "$candidate" || { rm -f -- "$candidate"; return 1; }
    if ! ln "$candidate" "$LOCK_FILE" 2>/dev/null; then
      [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]] || { rm -f -- "$candidate"; return 1; }
    fi
    rm -f -- "$candidate"
  fi
  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || return 1
  exec 9< "$LOCK_FILE" || return 1
  python3 - "$LOCK_FILE" 9 <<'PY'
import fcntl
import os
import stat
import sys

path = sys.argv[1]
fd = int(sys.argv[2])
fd_stat = os.fstat(fd)
path_stat = os.lstat(path)
if not stat.S_ISREG(path_stat.st_mode):
    raise SystemExit(1)
if (fd_stat.st_dev, fd_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino):
    raise SystemExit(1)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    raise SystemExit(1)
PY
  rc="$?"
  if [[ "$rc" -ne 0 ]]; then
    exec 9>&-
    return 1
  fi
}

CONTROL_DIR=""
TASK_DIR=""
MISSION=""
TASK_ID=""
PARENT_WORKTREE=""
EXPECTED_PARENT_TIP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; CONTROL_DIR="$2"; shift 2 ;;
    --task-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_DIR="$2"; shift 2 ;;
    --mission) [[ $# -ge 2 ]] || { usage; exit 1; }; MISSION="$2"; shift 2 ;;
    --task-id) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_ID="$2"; shift 2 ;;
    --parent-worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; PARENT_WORKTREE="$2"; shift 2 ;;
    --expected-parent-tip) [[ $# -ge 2 ]] || { usage; exit 1; }; EXPECTED_PARENT_TIP="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

for VALUE in "$CONTROL_DIR" "$TASK_DIR" "$MISSION" "$TASK_ID" "$PARENT_WORKTREE" "$EXPECTED_PARENT_TIP"; do
  [[ -n "$VALUE" ]] || { usage; exit 1; }
done
valid_identity "$MISSION" || fail "invalid mission identity"
valid_identity "$TASK_ID" || fail "invalid task identity"
case "$EXPECTED_PARENT_TIP" in *[!0-9a-fA-F]*|'') fail "invalid expected parent tip" ;; esac

CONTROL_PHYS="$(physical_existing_dir "$CONTROL_DIR")" || fail "control directory is missing or symlinked"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the coordinator integration lock"
acquire_integration_lock "$CONTROL_PHYS" || fail "coordinator integration lock is unsafe or busy"
TASK_PHYS="$(physical_existing_dir "$TASK_DIR")" || fail "task directory is missing or symlinked"
PARENT_PHYS="$(physical_existing_dir "$PARENT_WORKTREE")" || fail "parent worktree is missing or symlinked"
CONTROL_TASK="$CONTROL_PHYS/tasks/$TASK_ID"
MANIFEST="$CONTROL_TASK/worktrees.txt"
[[ -d "$CONTROL_TASK" && ! -L "$CONTROL_TASK" ]] || fail "coordinator task authority is missing or symlinked"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail "coordinator task manifest is missing or symlinked"

ROW_WORKTREE=""
ROW_BRANCH=""
ROW_BASE=""
ROW_REPO=""
ROW_EXTRA=""
IFS=$'\t' read -r ROW_WORKTREE ROW_BRANCH ROW_BASE ROW_REPO ROW_EXTRA < "$MANIFEST" || fail "cannot read coordinator task manifest"
[[ -n "$ROW_WORKTREE" && -n "$ROW_BRANCH" && -n "$ROW_BASE" && -n "$ROW_REPO" && -z "$ROW_EXTRA" ]] || fail "coordinator task manifest is malformed"
[[ "$(wc -l < "$MANIFEST" | tr -d ' ')" == 1 ]] || fail "coordinator task manifest must contain exactly one row"
[[ "$ROW_BRANCH" == "orc-task/$MISSION/$TASK_ID" ]] || fail "manifest branch is not the exact approved child branch"
case "$ROW_BASE" in *[!0-9a-fA-F]*|'') fail "manifest base is not a commit id" ;; esac

REPO_PHYS="$(physical_existing_dir "$ROW_REPO")" || fail "manifest repository is missing or symlinked"
REPO_COMMON="$(cd "$REPO_PHYS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "manifest repository is not Git"
PARENT_COMMON="$(cd "$PARENT_PHYS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "parent worktree is not Git"
[[ "$REPO_COMMON" == "$PARENT_COMMON" ]] || fail "manifest resources belong to different repositories"
[[ "$(git -C "$PARENT_PHYS" symbolic-ref --quiet --short HEAD)" == "orc/$MISSION" ]] || fail "parent worktree is not on the exact mission branch"

PARENT_TIP="$(git -C "$PARENT_PHYS" rev-parse --verify 'HEAD^{commit}')" || fail "cannot resolve parent tip"
[[ "$PARENT_TIP" == "$EXPECTED_PARENT_TIP" ]] || fail "parent tip changed from the coordinator expectation"
RESOLVED_BASE="$(git -C "$REPO_PHYS" rev-parse --verify "${ROW_BASE}^{commit}" 2>/dev/null)" || fail "manifest base does not resolve"
[[ "$RESOLVED_BASE" == "$ROW_BASE" ]] || fail "manifest base is not an exact commit id"
git -C "$REPO_PHYS" merge-base --is-ancestor "$ROW_BASE" "$PARENT_TIP" || fail "parent tip does not descend from the manifest base"

INTENT="$CONTROL_TASK/integration-intent"
CONTROL_STATE="$(read_single_value "$CONTROL_TASK/state" 2>/dev/null || true)"
RECORDED_INTEGRATED="$(read_single_value "$CONTROL_TASK/integrated_sha" 2>/dev/null || true)"
if [[ "$CONTROL_STATE" == integrated || "$CONTROL_STATE" == cleanup_pending || "$CONTROL_STATE" == collected ]]; then
  RECORDED_CHILD="$(read_single_value "$CONTROL_TASK/child_tip" 2>/dev/null || true)"
  [[ -n "$RECORDED_INTEGRATED" && -n "$RECORDED_CHILD" ]] || fail "terminal child state lacks integration authority"
  [[ "$(git -C "$REPO_PHYS" rev-parse --verify "${RECORDED_INTEGRATED}^{commit}" 2>/dev/null || true)" == "$RECORDED_INTEGRATED" ]] || fail "recorded integrated_sha is invalid"
  [[ "$(git -C "$REPO_PHYS" rev-parse --verify "${RECORDED_CHILD}^{commit}" 2>/dev/null || true)" == "$RECORDED_CHILD" ]] || fail "recorded child tip is invalid"
  git -C "$REPO_PHYS" merge-base --is-ancestor "$ROW_BASE" "$RECORDED_CHILD" || fail "recorded child tip does not descend from the manifest base"
  git -C "$REPO_PHYS" merge-base --is-ancestor "$RECORDED_CHILD" "$RECORDED_INTEGRATED" || fail "recorded integration does not contain the child tip"
  git -C "$REPO_PHYS" merge-base --is-ancestor "$RECORDED_INTEGRATED" "$PARENT_TIP" || fail "parent no longer contains the recorded integration"
  if [[ -e "$INTENT" || -L "$INTENT" ]]; then
    [[ -f "$INTENT" && ! -L "$INTENT" ]] || fail "terminal integration intent is unsafe"
    TERMINAL_INTENT_PARENT=""
    TERMINAL_INTENT_CHILD=""
    TERMINAL_INTENT_BRANCH=""
    TERMINAL_INTENT_EXTRA=""
    IFS=$'\t' read -r TERMINAL_INTENT_PARENT TERMINAL_INTENT_CHILD TERMINAL_INTENT_BRANCH TERMINAL_INTENT_EXTRA < "$INTENT" || fail "terminal integration intent is malformed"
    [[ -z "$TERMINAL_INTENT_EXTRA" && "$TERMINAL_INTENT_CHILD" == "$RECORDED_CHILD" && "$TERMINAL_INTENT_BRANCH" == "$ROW_BRANCH" && "$(wc -l < "$INTENT" | tr -d ' ')" == 1 ]] || fail "terminal integration intent does not match authority"
    [[ "$(git -C "$REPO_PHYS" rev-parse "${RECORDED_INTEGRATED}^1" 2>/dev/null || true)" == "$TERMINAL_INTENT_PARENT" && \
      "$(git -C "$REPO_PHYS" rev-parse "${RECORDED_INTEGRATED}^2" 2>/dev/null || true)" == "$RECORDED_CHILD" ]] || fail "terminal integration intent does not match recorded merge"
    rm -f -- "$INTENT"
  fi
  write_value "$TASK_PHYS/state" "$CONTROL_STATE" || fail "could not reconcile task state"
  echo "already integrated $TASK_ID at $RECORDED_INTEGRATED"
  exit 0
fi

CHILD_PHYS="$(physical_existing_dir "$ROW_WORKTREE")" || fail "manifest child worktree is missing or symlinked"
[[ "$CHILD_PHYS" == "$(cd "$ROW_WORKTREE" && pwd -P)" ]] || fail "child worktree cannot be canonicalized"
CHILD_COMMON="$(cd "$CHILD_PHYS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "child worktree is not Git"
[[ "$REPO_COMMON" == "$CHILD_COMMON" ]] || fail "child worktree belongs to another repository"
[[ "$(git -C "$CHILD_PHYS" symbolic-ref --quiet --short HEAD)" == "$ROW_BRANCH" ]] || fail "child worktree is not on the manifest branch"
CHILD_TIP="$(git -C "$CHILD_PHYS" rev-parse --verify 'HEAD^{commit}')" || fail "cannot resolve child tip"
BRANCH_TIP="$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${ROW_BRANCH}^{commit}")" || fail "manifest child branch is missing"
[[ "$BRANCH_TIP" == "$CHILD_TIP" ]] || fail "child branch and worktree tips differ"
git -C "$REPO_PHYS" merge-base --is-ancestor "$ROW_BASE" "$CHILD_TIP" || fail "child tip does not descend from the manifest base"

TASK_STATE="$(read_single_value "$TASK_PHYS/state" 2>/dev/null || true)"
[[ "$TASK_STATE" == completed ]] || fail "child task state must be completed"
[[ -s "$TASK_PHYS/report.md" && ! -L "$TASK_PHYS/report.md" ]] || fail "completed child report is missing or symlinked"
[[ ! -e "$CONTROL_TASK/unresolved-rework" && ! -L "$CONTROL_TASK/unresolved-rework" ]] || fail "task has unresolved rework"
CHILD_VERIFIED="$(read_single_value "$TASK_PHYS/verification.sha" 2>/dev/null || true)"
[[ "$CHILD_VERIFIED" == "$CHILD_TIP" ]] || fail "task verification does not attest the exact child tip"
PARENT_VERIFIED="$(read_single_value "$CONTROL_TASK/parent-verification.sha" 2>/dev/null || true)"
[[ "$PARENT_VERIFIED" == "$EXPECTED_PARENT_TIP" ]] || fail "parent verification does not attest the expected parent tip"
[[ -z "$(git -C "$CHILD_PHYS" status --porcelain --untracked-files=all)" ]] || fail "child worktree is dirty"
[[ -z "$(git -C "$PARENT_PHYS" status --porcelain --untracked-files=all)" ]] || fail "parent worktree is dirty"

if [[ -f "$INTENT" && ! -L "$INTENT" ]]; then
  INTENT_PARENT=""
  INTENT_CHILD=""
  INTENT_BRANCH=""
  INTENT_EXTRA=""
  IFS=$'\t' read -r INTENT_PARENT INTENT_CHILD INTENT_BRANCH INTENT_EXTRA < "$INTENT" || fail "integration intent is malformed"
  [[ "$INTENT_CHILD" == "$CHILD_TIP" && "$INTENT_BRANCH" == "$ROW_BRANCH" && -z "$INTENT_EXTRA" ]] || fail "integration intent does not match the child"
  [[ "$(wc -l < "$INTENT" | tr -d ' ')" == 1 ]] || fail "integration intent must contain exactly one row"
  [[ "$(git -C "$REPO_PHYS" rev-parse --verify "${INTENT_PARENT}^{commit}" 2>/dev/null || true)" == "$INTENT_PARENT" ]] || fail "integration intent parent is invalid"
  git -C "$REPO_PHYS" merge-base --is-ancestor "$ROW_BASE" "$INTENT_PARENT" || fail "integration intent parent does not descend from the manifest base"
else
  [[ ! -e "$INTENT" && ! -L "$INTENT" ]] || fail "integration intent is unsafe"
  INTENT_TMP="$(mktemp "$CONTROL_TASK/.integration-intent.XXXXXX")" || fail "cannot stage integration intent"
  printf '%s\t%s\t%s\n' "$EXPECTED_PARENT_TIP" "$CHILD_TIP" "$ROW_BRANCH" > "$INTENT_TMP"
  chmod 0600 "$INTENT_TMP"
  if ! ln "$INTENT_TMP" "$INTENT" 2>/dev/null; then
    rm -f -- "$INTENT_TMP"
    fail "integration intent publication raced"
  fi
  [[ "$INTENT_TMP" -ef "$INTENT" ]] || fail "integration intent publication ownership mismatch"
  rm -f -- "$INTENT_TMP"
  INTENT_PARENT="$EXPECTED_PARENT_TIP"
  INTENT_CHILD="$CHILD_TIP"
  INTENT_BRANCH="$ROW_BRANCH"
fi

RECOVERED_INTEGRATION=0
if [[ "$PARENT_TIP" != "$INTENT_PARENT" ]]; then
  FIRST_PARENT="$(git -C "$PARENT_PHYS" rev-parse "${PARENT_TIP}^1" 2>/dev/null || true)"
  SECOND_PARENT="$(git -C "$PARENT_PHYS" rev-parse "${PARENT_TIP}^2" 2>/dev/null || true)"
  [[ "$FIRST_PARENT" == "$INTENT_PARENT" && "$SECOND_PARENT" == "$CHILD_TIP" ]] || fail "parent moved beyond an exact interrupted integration"
  INTEGRATED_SHA="$PARENT_TIP"
  RECOVERED_INTEGRATION=1
else
  if git -C "$PARENT_PHYS" merge --no-ff --no-edit "$CHILD_TIP" >/dev/null 2>&1; then
    INTEGRATED_SHA="$(git -C "$PARENT_PHYS" rev-parse --verify 'HEAD^{commit}')" || fail "cannot resolve integrated parent tip"
  else
    git -C "$PARENT_PHYS" merge --abort >/dev/null 2>&1 || fail "merge failed and could not be aborted cleanly"
    rm -f -- "$INTENT"
    fail "child merge failed; parent restored"
  fi
fi

if [[ "${ORC_INTEGRATE_TEST_FAIL_AFTER_MERGE:-}" == 1 && "$RECOVERED_INTEGRATION" -eq 0 ]]; then
  fail "injected interruption after merge"
fi

FIRST_PARENT="$(git -C "$PARENT_PHYS" rev-parse "${INTEGRATED_SHA}^1")" || fail "integration did not create a merge commit"
SECOND_PARENT="$(git -C "$PARENT_PHYS" rev-parse "${INTEGRATED_SHA}^2")" || fail "integration did not preserve child history"
[[ "$FIRST_PARENT" == "$INTENT_PARENT" && "$SECOND_PARENT" == "$CHILD_TIP" ]] || fail "integration merge parents are not exact"
write_value "$CONTROL_TASK/parent-worktree" "$PARENT_PHYS" || fail "could not record parent worktree"
write_value "$CONTROL_TASK/parent_tip_before" "$INTENT_PARENT" || fail "could not record pre-integration parent tip"
write_value "$CONTROL_TASK/child_tip" "$CHILD_TIP" || fail "could not record child tip"
write_value "$CONTROL_TASK/integrated_sha" "$INTEGRATED_SHA" || fail "could not record integrated_sha"
write_value "$CONTROL_TASK/state" integrated || fail "could not record coordinator integrated state"
write_value "$TASK_PHYS/state" integrated || fail "could not record task integrated state"
rm -f -- "$INTENT"
echo "integrated $TASK_ID as $INTEGRATED_SHA"
