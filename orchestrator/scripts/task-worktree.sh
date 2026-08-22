#!/usr/bin/env bash
# Create or exactly reprovision one coordinator-owned child task worktree.

set -euo pipefail

LOCK_FILE=""
LOCK_CANDIDATE=""
LOCK_TOKEN=""
LOCK_OWNED=0
LOCK_CANDIDATE_OWNED=0
LOCK_PUBLISH_INTENT=0
NEW_AUTHORITY_DESTS=()
NEW_AUTHORITY_TEMPS=()

usage() {
  echo "usage: task-worktree.sh <create|reprovision> --control-dir <dir> --task-dir <dir> --mission <slug> --task-id <id> --repo <repo> --parent-worktree <dir> --worktree <dir> [--expected-generation <n>]" >&2
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

guarded_replace_batch() {
  python3 - "$@" <<'PY'
import os
import stat
import sys

values = sys.argv[1:]
if not values or len(values) % 2:
    raise SystemExit(1)
pairs = list(zip(values[0::2], values[1::2]))
snapshots = []
source_stats = []
restore_mode = os.environ.get("ORC_REPROVISION_RESTORE") == "1"
limit_name = ("ORC_REPROVISION_TEST_FAIL_RESTORE_AFTER" if restore_mode
              else "ORC_REPROVISION_TEST_FAIL_PUBLISH_AFTER")
failure_limit = int(os.environ.get(limit_name, "0"))
required_fsync_marker = os.environ.get("ORC_REPROVISION_REQUIRE_FSYNC_TEST_MARKER")
if required_fsync_marker and not os.path.isfile(required_fsync_marker):
    raise SystemExit(96)
for source, destination in pairs:
    source_stat = os.lstat(source)
    destination_stat = os.lstat(destination)
    if not stat.S_ISREG(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
        raise SystemExit(1)
    if not stat.S_ISREG(destination_stat.st_mode) or stat.S_ISLNK(destination_stat.st_mode):
        raise SystemExit(1)
    source_stats.append(source_stat)
    snapshots.append((destination_stat.st_dev, destination_stat.st_ino))
for (_, destination), snapshot in zip(pairs, snapshots):
    current = os.lstat(destination)
    if (not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode) or
            (current.st_dev, current.st_ino) != snapshot):
        raise SystemExit(1)
replace_count = 0
for (source, destination), source_stat in zip(pairs, source_stats):
    os.replace(source, destination)
    replace_count += 1
    published = os.lstat(destination)
    if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or
            (published.st_dev, published.st_ino) != (source_stat.st_dev, source_stat.st_ino)):
        raise SystemExit(1)
    if failure_limit and replace_count == failure_limit:
        raise SystemExit(97)
for directory in {os.path.dirname(destination) or "." for _, destination in pairs}:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

durable_fsync_paths() {
  python3 - "$@" <<'PY'
import os
import stat
import sys

paths = sys.argv[1:]
if not paths:
    raise SystemExit(1)
directories = set()
for path in paths:
    path_stat = os.lstat(path)
    if stat.S_ISLNK(path_stat.st_mode) or not (stat.S_ISREG(path_stat.st_mode) or stat.S_ISDIR(path_stat.st_mode)):
        raise SystemExit(1)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    descriptor_stat = os.fstat(descriptor)
    if ((descriptor_stat.st_dev, descriptor_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino) or
            stat.S_IFMT(descriptor_stat.st_mode) != stat.S_IFMT(path_stat.st_mode)):
        os.close(descriptor)
        raise SystemExit(1)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directories.add(os.path.dirname(path) or ".")
for directory in directories:
    directory_stat = os.lstat(directory)
    if not stat.S_ISDIR(directory_stat.st_mode) or stat.S_ISLNK(directory_stat.st_mode):
        raise SystemExit(1)
    descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
marker = os.environ.get("ORC_REPROVISION_FSYNC_TEST_MARKER")
if marker and os.environ.get("ORC_REPROVISION_FSYNC_PHASE") == "authority":
    descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, b"authority-fsynced\n")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.path.dirname(marker) or "."
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

publish_reprovision_completion() {
  local receipt="$1" old_generation="$2" new_generation="$3" old_base="$4" new_base="$5"
  local temporary
  temporary="$(mktemp "$CONTROL_TASK_DIR/.reprovision-completion.XXXXXX")" || return 1
  if ! python3 - "$temporary" "$MISSION" "$TASK_ID" "$old_generation" "$new_generation" \
      "$PARENT_PHYS" "$REPO_PHYS" "$WORKTREE_PHYS" "$TASK_PHYS" "$BRANCH" \
      "$old_base" "$new_base" "$CONTROL_MANIFEST" "$WORKER_MANIFEST" \
      "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" "$WORKER_SANDBOX" \
      "$CONTROL_STATE" "$WORKER_STATE" "$CONTROL_TASK_DIR/accepted-thread-id" \
      "$TASK_PHYS/accepted-thread-id" "$CONTROL_TASK_DIR/task-window-state" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

(output, mission, task, old_generation, new_generation, parent, repo, worktree,
 task_dir, branch, old_base, new_base, control_manifest_path, worker_manifest_path,
 control_generation_path, worker_generation_path, control_sandbox_path,
 worker_sandbox_path, control_state_path, worker_state_path, control_thread_path,
 worker_thread_path, task_window_state_path) = sys.argv[1:]

def regular_bytes(path):
    path_stat = os.lstat(path)
    if not stat.S_ISREG(path_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode):
        raise SystemExit(1)
    with open(path, "rb") as handle:
        return handle.read()

def scalar(path):
    data = regular_bytes(path)
    if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\x00" in data:
        raise SystemExit(1)
    value = data[:-1].decode("utf-8")
    if not value or "\t" in value:
        raise SystemExit(1)
    return value, data

def manifest(path):
    data = regular_bytes(path)
    if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\x00" in data:
        raise SystemExit(1)
    text = data.decode("utf-8")
    if len(text[:-1].split("\t")) != 4 or any(not item for item in text[:-1].split("\t")):
        raise SystemExit(1)
    return text, data

control_manifest, control_manifest_bytes = manifest(control_manifest_path)
worker_manifest, worker_manifest_bytes = manifest(worker_manifest_path)
if control_manifest_bytes != worker_manifest_bytes:
    raise SystemExit(1)
control_generation, control_generation_bytes = scalar(control_generation_path)
worker_generation, worker_generation_bytes = scalar(worker_generation_path)
control_sandbox, control_sandbox_bytes = scalar(control_sandbox_path)
worker_sandbox, worker_sandbox_bytes = scalar(worker_sandbox_path)
control_state, control_state_bytes = scalar(control_state_path)
worker_state, worker_state_bytes = scalar(worker_state_path)
control_thread, control_thread_bytes = scalar(control_thread_path)
worker_thread, worker_thread_bytes = scalar(worker_thread_path)
task_window_state, task_window_state_bytes = scalar(task_window_state_path)
if (control_generation != new_generation or worker_generation != new_generation or
        control_sandbox != worktree or worker_sandbox != worktree or
        control_state != "ready" or worker_state != "ready" or
        control_thread != worker_thread or task_window_state != "unarchived"):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{40,64}", old_base) or not re.fullmatch(r"[0-9a-f]{40,64}", new_base):
    raise SystemExit(1)

def digest(data):
    return hashlib.sha256(data).hexdigest()

authority_hashes = {
    "control_generation": digest(control_generation_bytes),
    "worker_generation": digest(worker_generation_bytes),
    "control_sandbox": digest(control_sandbox_bytes),
    "worker_sandbox": digest(worker_sandbox_bytes),
    "control_state": digest(control_state_bytes),
    "worker_state": digest(worker_state_bytes),
    "control_thread": digest(control_thread_bytes),
    "worker_thread": digest(worker_thread_bytes),
    "task_window_state": digest(task_window_state_bytes),
}
receipt = {
    "version": 1,
    "mission": mission,
    "task": task,
    "old_generation": int(old_generation),
    "new_generation": int(new_generation),
    "parent_worktree": parent,
    "repo": repo,
    "worktree": worktree,
    "task_dir": task_dir,
    "branch": branch,
    "old_base": old_base,
    "new_base": new_base,
    "parent_tip": new_base,
    "accepted_thread_id": control_thread,
    "sandbox_root": worktree,
    "control_manifest_content": control_manifest,
    "control_manifest_sha256": digest(control_manifest_bytes),
    "worker_manifest_content": worker_manifest,
    "worker_manifest_sha256": digest(worker_manifest_bytes),
    "authority_sha256": authority_hashes,
    "branch_tip": new_base,
    "worktree_tip": new_base,
}
encoded = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
descriptor = os.open(output, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
try:
    os.write(descriptor, encoded)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  durable_fsync_paths "$temporary" || { rm -f -- "$temporary"; return 1; }
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    [[ -f "$receipt" && ! -L "$receipt" ]] || { rm -f -- "$temporary"; return 1; }
    guarded_replace_batch "$temporary" "$receipt" || { rm -f -- "$temporary"; return 1; }
  else
    if ! ln "$temporary" "$receipt" 2>/dev/null; then
      rm -f -- "$temporary"
      return 1
    fi
    [[ "$temporary" -ef "$receipt" ]] || { rm -f -- "$temporary"; return 1; }
    rm -f -- "$temporary"
  fi
  durable_fsync_paths "$receipt" "$CONTROL_TASK_DIR" || return 1
}

validate_reprovision_completion() {
  local receipt="$1" expected_old_generation="$2" expected_new_generation="$3"
  local branch_tip worktree_tip
  branch_tip="$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)"
  worktree_tip="$(git -C "$WORKTREE_PHYS" rev-parse HEAD 2>/dev/null || true)"
  python3 - "$receipt" "$MISSION" "$TASK_ID" "$expected_old_generation" "$expected_new_generation" \
    "$PARENT_PHYS" "$REPO_PHYS" "$WORKTREE_PHYS" "$TASK_PHYS" "$BRANCH" "$PARENT_TIP" \
    "$branch_tip" "$worktree_tip" "$CONTROL_MANIFEST" "$WORKER_MANIFEST" \
    "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" "$WORKER_SANDBOX" \
    "$CONTROL_STATE" "$WORKER_STATE" "$CONTROL_TASK_DIR/accepted-thread-id" \
    "$TASK_PHYS/accepted-thread-id" "$CONTROL_TASK_DIR/task-window-state" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

(receipt_path, mission, task, expected_old_generation, expected_new_generation,
 parent, repo, worktree, task_dir, branch, parent_tip, branch_tip, worktree_tip,
 control_manifest_path, worker_manifest_path, control_generation_path,
 worker_generation_path, control_sandbox_path, worker_sandbox_path,
 control_state_path, worker_state_path, control_thread_path, worker_thread_path,
 task_window_state_path) = sys.argv[1:]

def regular_bytes(path):
    path_stat = os.lstat(path)
    if not stat.S_ISREG(path_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode):
        raise SystemExit(1)
    with open(path, "rb") as handle:
        return handle.read()

def scalar(path):
    data = regular_bytes(path)
    if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\x00" in data:
        raise SystemExit(1)
    value = data[:-1].decode("utf-8")
    if not value or "\t" in value:
        raise SystemExit(1)
    return value, data

def manifest(path):
    data = regular_bytes(path)
    if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\x00" in data:
        raise SystemExit(1)
    text = data.decode("utf-8")
    if len(text[:-1].split("\t")) != 4 or any(not item for item in text[:-1].split("\t")):
        raise SystemExit(1)
    return text, data

raw = regular_bytes(receipt_path)
if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
    raise SystemExit(1)
try:
    receipt = json.loads(raw.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
canonical = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
if raw != canonical:
    raise SystemExit(1)
expected_keys = {
    "version", "mission", "task", "old_generation", "new_generation",
    "parent_worktree", "repo", "worktree", "task_dir", "branch", "old_base",
    "new_base", "parent_tip", "accepted_thread_id", "sandbox_root",
    "control_manifest_content", "control_manifest_sha256", "worker_manifest_content",
    "worker_manifest_sha256", "authority_sha256", "branch_tip", "worktree_tip",
}
if set(receipt) != expected_keys or receipt.get("version") != 1:
    raise SystemExit(1)
if (receipt["mission"] != mission or receipt["task"] != task or
        receipt["old_generation"] != int(expected_old_generation) or
        receipt["new_generation"] != int(expected_new_generation) or
        receipt["parent_worktree"] != parent or receipt["repo"] != repo or
        receipt["worktree"] != worktree or receipt["task_dir"] != task_dir or
        receipt["branch"] != branch or receipt["new_base"] != parent_tip or
        receipt["parent_tip"] != parent_tip or receipt["branch_tip"] != branch_tip or
        receipt["worktree_tip"] != worktree_tip or receipt["sandbox_root"] != worktree):
    raise SystemExit(1)
if not isinstance(receipt["old_base"], str) or not re.fullmatch(r"[0-9a-f]{40,64}", receipt["old_base"]):
    raise SystemExit(1)

control_manifest, control_manifest_bytes = manifest(control_manifest_path)
worker_manifest, worker_manifest_bytes = manifest(worker_manifest_path)
control_generation, control_generation_bytes = scalar(control_generation_path)
worker_generation, worker_generation_bytes = scalar(worker_generation_path)
control_sandbox, control_sandbox_bytes = scalar(control_sandbox_path)
worker_sandbox, worker_sandbox_bytes = scalar(worker_sandbox_path)
control_state, control_state_bytes = scalar(control_state_path)
worker_state, worker_state_bytes = scalar(worker_state_path)
control_thread, control_thread_bytes = scalar(control_thread_path)
worker_thread, worker_thread_bytes = scalar(worker_thread_path)
task_window_state, task_window_state_bytes = scalar(task_window_state_path)
if (control_manifest_bytes != worker_manifest_bytes or control_generation != expected_new_generation or
        worker_generation != expected_new_generation or control_sandbox != worktree or
        worker_sandbox != worktree or control_state != "ready" or worker_state != "ready" or
        control_thread != worker_thread or control_thread != receipt["accepted_thread_id"] or
        task_window_state != "unarchived"):
    raise SystemExit(1)

def digest(data):
    return hashlib.sha256(data).hexdigest()

expected_hashes = {
    "control_generation": digest(control_generation_bytes),
    "worker_generation": digest(worker_generation_bytes),
    "control_sandbox": digest(control_sandbox_bytes),
    "worker_sandbox": digest(worker_sandbox_bytes),
    "control_state": digest(control_state_bytes),
    "worker_state": digest(worker_state_bytes),
    "control_thread": digest(control_thread_bytes),
    "worker_thread": digest(worker_thread_bytes),
    "task_window_state": digest(task_window_state_bytes),
}
if (receipt["control_manifest_content"] != control_manifest or
        receipt["worker_manifest_content"] != worker_manifest or
        receipt["control_manifest_sha256"] != digest(control_manifest_bytes) or
        receipt["worker_manifest_sha256"] != digest(worker_manifest_bytes) or
        receipt["authority_sha256"] != expected_hashes):
    raise SystemExit(1)
PY
}

publish_new_authority() {
  local destination="$1" value="$2" temporary
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  temporary="$(mktemp "$(dirname "$destination")/.${destination##*/}.XXXXXX")" || return 1
  printf '%s\n' "$value" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  if ! ln "$temporary" "$destination" 2>/dev/null; then
    rm -f -- "$temporary"
    return 1
  fi
  if [[ ! "$temporary" -ef "$destination" ]]; then
    rm -f -- "$temporary"
    return 1
  fi
  NEW_AUTHORITY_DESTS+=("$destination")
  NEW_AUTHORITY_TEMPS+=("$temporary")
}

cleanup_new_authority() {
  local index destination temporary ok=1
  for ((index=${#NEW_AUTHORITY_DESTS[@]} - 1; index >= 0; index--)); do
    destination="${NEW_AUTHORITY_DESTS[$index]}"
    temporary="${NEW_AUTHORITY_TEMPS[$index]}"
    if [[ -f "$destination" && ! -L "$destination" && -f "$temporary" && ! -L "$temporary" && "$destination" -ef "$temporary" ]]; then
      rm -f -- "$destination" || ok=0
    elif [[ -e "$destination" || -L "$destination" ]]; then
      ok=0
    fi
    rm -f -- "$temporary"
  done
  NEW_AUTHORITY_DESTS=()
  NEW_AUTHORITY_TEMPS=()
  [[ "$ok" -eq 1 ]]
}

finalize_new_authority() {
  local temporary
  for temporary in "${NEW_AUTHORITY_TEMPS[@]}"; do
    rm -f -- "$temporary" || return 1
  done
  NEW_AUTHORITY_DESTS=()
  NEW_AUTHORITY_TEMPS=()
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

MODE="${1:-}"
case "$MODE" in
  create|reprovision) ;;
  *) usage; exit 1 ;;
esac
shift

CONTROL_DIR=""
TASK_DIR=""
MISSION=""
TASK_ID=""
REPO=""
PARENT_WORKTREE=""
WORKTREE=""
EXPECTED_GENERATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; CONTROL_DIR="$2"; shift 2 ;;
    --task-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_DIR="$2"; shift 2 ;;
    --mission) [[ $# -ge 2 ]] || { usage; exit 1; }; MISSION="$2"; shift 2 ;;
    --task-id) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_ID="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { usage; exit 1; }; REPO="$2"; shift 2 ;;
    --parent-worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; PARENT_WORKTREE="$2"; shift 2 ;;
    --worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; WORKTREE="$2"; shift 2 ;;
    --expected-generation) [[ $# -ge 2 ]] || { usage; exit 1; }; EXPECTED_GENERATION="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [[ "$MODE" == create ]]; then
  [[ -z "$EXPECTED_GENERATION" ]] || fail "create does not accept an expected generation"
else
  case "$EXPECTED_GENERATION" in
    ''|*[!0-9]*|0) fail "reprovision requires a positive expected generation" ;;
  esac
fi

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
REPROVISION_RECOVERY=0
REPROVISION_COMPLETION_CANDIDATE=0
if [[ "$MODE" == reprovision && -f "$CONTROL_DIR/tasks/$TASK_ID/reprovision-intent" && \
  ! -L "$CONTROL_DIR/tasks/$TASK_ID/reprovision-intent" ]]; then
  REPROVISION_RECOVERY=1
fi
if [[ "$MODE" == reprovision && "$REPROVISION_RECOVERY" -eq 0 && -d "$WORKTREE" && ! -L "$WORKTREE" ]]; then
  REPROVISION_COMPLETION_CANDIDATE=1
fi
if [[ -e "$WORKTREE" || -L "$WORKTREE" ]]; then
  [[ ( "$REPROVISION_RECOVERY" -eq 1 || "$REPROVISION_COMPLETION_CANDIDATE" -eq 1 ) && \
    -d "$WORKTREE" && ! -L "$WORKTREE" ]] || fail "child worktree already exists: $WORKTREE"
fi
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
CONTROL_GENERATION="$CONTROL_TASK_DIR/generation"
WORKER_GENERATION="$TASK_PHYS/generation"
CONTROL_SANDBOX="$CONTROL_TASK_DIR/sandbox-root"
WORKER_SANDBOX="$TASK_PHYS/sandbox-root"
CONTROL_STATE="$CONTROL_TASK_DIR/state"
WORKER_STATE="$TASK_PHYS/state"

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
if [[ -e "$CONTROL_MANIFEST" || -L "$CONTROL_MANIFEST" ]]; then
  [[ -f "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" ]] || fail "coordinator manifest is unsafe"
  CONTROL_MANIFEST_PHYS="$(cd "$(dirname "$CONTROL_MANIFEST")" && pwd -P)/$(basename "$CONTROL_MANIFEST")"
else
  CONTROL_MANIFEST_PHYS="$(physical_path "$CONTROL_MANIFEST")" || fail "cannot canonicalize coordinator manifest"
fi

paths_overlap "$WORKTREE_PHYS" "$TASK_PHYS" && fail "child worktree and task directory overlap"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$PARENT_PHYS" && fail "coordinator manifest overlaps the parent worktree"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$WORKTREE_PHYS" && fail "coordinator manifest overlaps the child worktree"
paths_overlap "$CONTROL_MANIFEST_PHYS" "$TASK_PHYS" && fail "coordinator manifest overlaps the task directory"

while IFS= read -r GIT_WORKTREE; do
  [[ -n "$GIT_WORKTREE" ]] || continue
  GIT_WORKTREE_PHYS="$(physical_path "$GIT_WORKTREE")" || fail "cannot canonicalize registered Git worktree: $GIT_WORKTREE"
  if paths_overlap "$WORKTREE_PHYS" "$GIT_WORKTREE_PHYS"; then
    [[ ( "$REPROVISION_RECOVERY" -eq 1 || "$REPROVISION_COMPLETION_CANDIDATE" -eq 1 ) && \
      "$WORKTREE_PHYS" == "$GIT_WORKTREE_PHYS" ]] || fail "child worktree overlaps a registered Git worktree"
  fi
  paths_overlap "$TASK_PHYS" "$GIT_WORKTREE_PHYS" && fail "task directory overlaps a registered Git worktree"
  paths_overlap "$CONTROL_MANIFEST_PHYS" "$GIT_WORKTREE_PHYS" && fail "coordinator manifest overlaps a registered Git worktree"
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')

if [[ "$MODE" == reprovision ]]; then
  [[ -f "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" ]] || fail "retained coordinator manifest is missing or unsafe"
  [[ -f "$WORKER_MANIFEST" && ! -L "$WORKER_MANIFEST" ]] || fail "retained worker manifest is missing or unsafe"
  [[ ! "$CONTROL_MANIFEST" -ef "$WORKER_MANIFEST" ]] || fail "worker manifest must remain a separate copy"
  REPROVISION_INTENT="$CONTROL_TASK_DIR/reprovision-intent"
  REPROVISION_COMPLETION="$CONTROL_TASK_DIR/reprovision-completion.json"
  if [[ "$REPROVISION_COMPLETION_CANDIDATE" -eq 1 && ! -e "$REPROVISION_INTENT" && ! -L "$REPROVISION_INTENT" ]]; then
    COMPLETED_GENERATION=$((EXPECTED_GENERATION + 1))
    COMPLETED_EXPECTED_ROW="$(printf '%s\t%s\t%s\t%s' "$WORKTREE_PHYS" "$BRANCH" "$PARENT_TIP" "$REPO_PHYS")"
    COMPLETION_MATCH=1
    for COMPLETION_AUTHORITY in "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" \
      "$WORKER_SANDBOX" "$CONTROL_STATE" "$WORKER_STATE" \
      "$CONTROL_TASK_DIR/accepted-thread-id" "$TASK_PHYS/accepted-thread-id" \
      "$CONTROL_TASK_DIR/task-window-state"; do
      [[ -f "$COMPLETION_AUTHORITY" && ! -L "$COMPLETION_AUTHORITY" ]] || COMPLETION_MATCH=0
    done
    if [[ "$COMPLETION_MATCH" -eq 1 ]]; then
      [[ "$(tr -d '[:space:]' < "$CONTROL_GENERATION")" == "$COMPLETED_GENERATION" && \
        "$(tr -d '[:space:]' < "$WORKER_GENERATION")" == "$COMPLETED_GENERATION" && \
        "$(tr -d '[:space:]' < "$CONTROL_STATE")" == ready && \
        "$(tr -d '[:space:]' < "$WORKER_STATE")" == ready && \
        "$(tr -d '\n' < "$CONTROL_SANDBOX")" == "$WORKTREE_PHYS" && \
        "$(tr -d '\n' < "$WORKER_SANDBOX")" == "$WORKTREE_PHYS" && \
        "$(tr -d '\n' < "$CONTROL_MANIFEST")" == "$COMPLETED_EXPECTED_ROW" && \
        "$(tr -d '[:space:]' < "$CONTROL_TASK_DIR/task-window-state")" == unarchived && \
        -n "$(tr -d '\n' < "$CONTROL_TASK_DIR/accepted-thread-id")" ]] || COMPLETION_MATCH=0
      cmp -s "$CONTROL_MANIFEST" "$WORKER_MANIFEST" || COMPLETION_MATCH=0
      git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxq "worktree $WORKTREE_PHYS" || COMPLETION_MATCH=0
      [[ "$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$BRANCH" && \
        "$(git -C "$WORKTREE_PHYS" rev-parse HEAD 2>/dev/null || true)" == "$PARENT_TIP" && \
        -z "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" && \
        "$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)" == "$PARENT_TIP" ]] || COMPLETION_MATCH=0
      validate_reprovision_completion "$CONTROL_TASK_DIR/reprovision-completion.json" \
        "$EXPECTED_GENERATION" "$COMPLETED_GENERATION" || COMPLETION_MATCH=0
    fi
    [[ "$COMPLETION_MATCH" -eq 1 ]] || fail "existing child resources do not match an exact completed reprovision epoch"
    for COMPLETION_DIR in "$CONTROL_TASK_DIR"/.reprovision-stage.* \
      "$CONTROL_TASK_DIR"/.reprovision-backup.* "$TASK_PHYS"/.reprovision-stage.*; do
      [[ -e "$COMPLETION_DIR" || -L "$COMPLETION_DIR" ]] || continue
      [[ -d "$COMPLETION_DIR" && ! -L "$COMPLETION_DIR" ]] || fail "completed reprovision artifact is unsafe: $COMPLETION_DIR"
      rm -rf -- "$COMPLETION_DIR"
    done
    durable_fsync_paths "$CONTROL_TASK_DIR" "$TASK_PHYS" || fail "could not sync completed reprovision cleanup"
    release_lock || fail "could not release coordinator mutation lock"
    trap - EXIT HUP INT TERM
    echo "already reprovisioned $BRANCH generation $COMPLETED_GENERATION at $PARENT_TIP in $WORKTREE_PHYS"
    exit 0
  fi
  if [[ -e "$REPROVISION_INTENT" || -L "$REPROVISION_INTENT" ]]; then
    [[ -f "$REPROVISION_INTENT" && ! -L "$REPROVISION_INTENT" ]] || fail "reprovision recovery intent is unsafe"
    INTENT_OLD_GENERATION=""; INTENT_NEW_GENERATION=""; INTENT_OLD_BASE=""; INTENT_NEW_BASE=""
    INTENT_WORKTREE=""; INTENT_BRANCH=""; INTENT_THREAD=""; INTENT_EXTRA=""
    IFS=$'\t' read -r INTENT_OLD_GENERATION INTENT_NEW_GENERATION INTENT_OLD_BASE INTENT_NEW_BASE \
      INTENT_WORKTREE INTENT_BRANCH INTENT_THREAD INTENT_EXTRA < "$REPROVISION_INTENT" || fail "reprovision recovery intent cannot be read"
    [[ -z "$INTENT_EXTRA" && "$(wc -l < "$REPROVISION_INTENT" | tr -d ' ')" == 1 ]] || fail "reprovision recovery intent is malformed"
    [[ "$INTENT_OLD_GENERATION" == "$EXPECTED_GENERATION" && \
      "$INTENT_NEW_GENERATION" -eq $((EXPECTED_GENERATION + 1)) ]] || fail "reprovision recovery generation differs from the request"
    [[ "$(git -C "$REPO_PHYS" rev-parse --verify "${INTENT_OLD_BASE}^{commit}" 2>/dev/null || true)" == "$INTENT_OLD_BASE" ]] || fail "reprovision recovery old base is invalid"
    git -C "$REPO_PHYS" merge-base --is-ancestor "$INTENT_OLD_BASE" "$INTENT_NEW_BASE" || fail "reprovision recovery base ancestry changed"
    [[ "$INTENT_NEW_BASE" == "$PARENT_TIP" && "$INTENT_WORKTREE" == "$WORKTREE_PHYS" && \
      "$INTENT_BRANCH" == "$BRANCH" ]] || fail "reprovision recovery intent differs from exact arguments"
    [[ -f "$CONTROL_TASK_DIR/accepted-thread-id" && ! -L "$CONTROL_TASK_DIR/accepted-thread-id" && \
      "$(tr -d '\n' < "$CONTROL_TASK_DIR/accepted-thread-id")" == "$INTENT_THREAD" ]] || fail "reprovision recovery thread identity changed"
    [[ -f "$TASK_PHYS/accepted-thread-id" && ! -L "$TASK_PHYS/accepted-thread-id" && \
      "$(tr -d '\n' < "$TASK_PHYS/accepted-thread-id")" == "$INTENT_THREAD" ]] || fail "worker reprovision recovery thread identity changed"
    [[ -f "$CONTROL_TASK_DIR/task-window-state" && ! -L "$CONTROL_TASK_DIR/task-window-state" && \
      "$(tr -d '[:space:]' < "$CONTROL_TASK_DIR/task-window-state")" == unarchived ]] || fail "reprovision recovery thread is not unarchived"
    [[ -d "$WORKTREE_PHYS" && ! -L "$WORKTREE_PHYS" ]] || fail "reprovision recovery worktree is missing or unsafe"
    git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxq "worktree $WORKTREE_PHYS" || fail "reprovision recovery worktree is not registered"
    [[ "$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$BRANCH" && \
      "$(git -C "$WORKTREE_PHYS" rev-parse HEAD 2>/dev/null || true)" == "$INTENT_NEW_BASE" && \
      -z "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" ]] || fail "reprovision recovery worktree changed"
    [[ "$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)" == "$INTENT_NEW_BASE" ]] || fail "reprovision recovery branch changed"
    for RECOVERY_AUTHORITY in "$CONTROL_MANIFEST" "$WORKER_MANIFEST" "$CONTROL_GENERATION" \
      "$WORKER_GENERATION" "$CONTROL_SANDBOX" "$WORKER_SANDBOX" "$CONTROL_STATE" "$WORKER_STATE"; do
      [[ -f "$RECOVERY_AUTHORITY" && ! -L "$RECOVERY_AUTHORITY" ]] || fail "mixed reprovision authority is unsafe: $RECOVERY_AUTHORITY"
    done
    RECOVERY_EXPECTED_ROW="$(printf '%s\t%s\t%s\t%s' "$WORKTREE_PHYS" "$BRANCH" "$INTENT_NEW_BASE" "$REPO_PHYS")"
    RECOVERY_CONVERGED=0
    if [[ "$(tr -d '[:space:]' < "$CONTROL_GENERATION")" == "$INTENT_NEW_GENERATION" && \
      "$(tr -d '[:space:]' < "$WORKER_GENERATION")" == "$INTENT_NEW_GENERATION" && \
      "$(tr -d '[:space:]' < "$CONTROL_STATE")" == ready && \
      "$(tr -d '[:space:]' < "$WORKER_STATE")" == ready && \
      "$(tr -d '\n' < "$CONTROL_SANDBOX")" == "$WORKTREE_PHYS" && \
      "$(tr -d '\n' < "$WORKER_SANDBOX")" == "$WORKTREE_PHYS" && \
      "$(tr -d '\n' < "$CONTROL_MANIFEST")" == "$RECOVERY_EXPECTED_ROW" ]] && \
      cmp -s "$CONTROL_MANIFEST" "$WORKER_MANIFEST"; then
      RECOVERY_CONVERGED=1
    fi
    if [[ "$RECOVERY_CONVERGED" -eq 1 ]]; then
      publish_reprovision_completion "$REPROVISION_COMPLETION" "$INTENT_OLD_GENERATION" \
        "$INTENT_NEW_GENERATION" "$INTENT_OLD_BASE" "$INTENT_NEW_BASE" || \
        fail "could not publish recovered reprovision completion receipt"
      for RECOVERY_DIR in "$CONTROL_TASK_DIR"/.reprovision-stage.* \
        "$CONTROL_TASK_DIR"/.reprovision-backup.* "$TASK_PHYS"/.reprovision-stage.*; do
        [[ -e "$RECOVERY_DIR" || -L "$RECOVERY_DIR" ]] || continue
        [[ -d "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] || fail "reprovision recovery artifact is unsafe: $RECOVERY_DIR"
        rm -rf -- "$RECOVERY_DIR"
      done
      rm -f -- "$REPROVISION_INTENT"
      durable_fsync_paths "$CONTROL_TASK_DIR" "$TASK_PHYS" || fail "could not sync reconciled reprovision completion"
      if [[ "${ORC_REPROVISION_TEST_FAIL_AFTER_INTENT_REMOVAL_RECOVERY:-}" == 1 ]]; then
        fail "injected interruption after recovered reprovision intent removal"
      fi
      release_lock || fail "could not release coordinator mutation lock"
      trap - EXIT HUP INT TERM
      echo "reconciled existing $BRANCH generation $INTENT_NEW_GENERATION at $INTENT_NEW_BASE in $WORKTREE_PHYS"
      exit 0
    fi
    [[ -n "$(find "$CONTROL_TASK_DIR" -maxdepth 1 -name '.reprovision-stage.*' -type d -print -quit)" && \
      -n "$(find "$CONTROL_TASK_DIR" -maxdepth 1 -name '.reprovision-backup.*' -type d -print -quit)" && \
      -n "$(find "$TASK_PHYS" -maxdepth 1 -name '.reprovision-stage.*' -type d -print -quit)" ]] || fail "reprovision recovery staging or backups are missing"

    RECOVERY_CONTROL_STAGE="$(mktemp -d "$CONTROL_TASK_DIR/.reprovision-stage.XXXXXX")" || fail "cannot stage reprovision recovery"
    RECOVERY_WORKER_STAGE="$(mktemp -d "$TASK_PHYS/.reprovision-stage.XXXXXX")" || fail "cannot stage worker reprovision recovery"
    printf '%s\t%s\t%s\t%s\n' "$WORKTREE_PHYS" "$BRANCH" "$INTENT_NEW_BASE" "$REPO_PHYS" > "$RECOVERY_CONTROL_STAGE/worktrees.txt"
    cp "$RECOVERY_CONTROL_STAGE/worktrees.txt" "$RECOVERY_WORKER_STAGE/worktrees.txt"
    printf '%s\n' "$INTENT_NEW_GENERATION" > "$RECOVERY_CONTROL_STAGE/generation"
    cp "$RECOVERY_CONTROL_STAGE/generation" "$RECOVERY_WORKER_STAGE/generation"
    printf '%s\n' "$WORKTREE_PHYS" > "$RECOVERY_CONTROL_STAGE/sandbox-root"
    cp "$RECOVERY_CONTROL_STAGE/sandbox-root" "$RECOVERY_WORKER_STAGE/sandbox-root"
    printf 'ready\n' > "$RECOVERY_CONTROL_STAGE/state"
    cp "$RECOVERY_CONTROL_STAGE/state" "$RECOVERY_WORKER_STAGE/state"
    chmod 0600 "$RECOVERY_CONTROL_STAGE"/* "$RECOVERY_WORKER_STAGE"/*
    ORC_REPROVISION_FSYNC_PHASE=authority durable_fsync_paths \
      "$RECOVERY_CONTROL_STAGE"/* "$RECOVERY_WORKER_STAGE"/* \
      "$RECOVERY_CONTROL_STAGE" "$RECOVERY_WORKER_STAGE" || \
      fail "could not sync reprovision recovery staging"
    if ! guarded_replace_batch \
        "$RECOVERY_CONTROL_STAGE/worktrees.txt" "$CONTROL_MANIFEST" \
        "$RECOVERY_WORKER_STAGE/worktrees.txt" "$WORKER_MANIFEST" \
        "$RECOVERY_CONTROL_STAGE/generation" "$CONTROL_GENERATION" \
        "$RECOVERY_WORKER_STAGE/generation" "$WORKER_GENERATION" \
        "$RECOVERY_CONTROL_STAGE/sandbox-root" "$CONTROL_SANDBOX" \
        "$RECOVERY_WORKER_STAGE/sandbox-root" "$WORKER_SANDBOX" \
        "$RECOVERY_CONTROL_STAGE/state" "$CONTROL_STATE" \
        "$RECOVERY_WORKER_STAGE/state" "$WORKER_STATE"; then
      fail "reprovision recovery publication failed; durable evidence preserved"
    fi
    [[ "$(tr -d '[:space:]' < "$CONTROL_GENERATION")" == "$INTENT_NEW_GENERATION" && \
      "$(tr -d '[:space:]' < "$WORKER_GENERATION")" == "$INTENT_NEW_GENERATION" && \
      "$(tr -d '[:space:]' < "$CONTROL_STATE")" == ready && \
      "$(tr -d '[:space:]' < "$WORKER_STATE")" == ready ]] || fail "reprovision recovery authority did not converge"
    cmp -s "$CONTROL_MANIFEST" "$WORKER_MANIFEST" || fail "reprovision recovery manifests did not converge"
    if [[ "${ORC_REPROVISION_TEST_FAIL_AFTER_CONVERGE:-}" == 1 ]]; then
      fail "injected interruption after reprovision authority convergence"
    fi
    publish_reprovision_completion "$REPROVISION_COMPLETION" "$INTENT_OLD_GENERATION" \
      "$INTENT_NEW_GENERATION" "$INTENT_OLD_BASE" "$INTENT_NEW_BASE" || \
      fail "could not publish reprovision recovery completion receipt"
    for RECOVERY_DIR in "$CONTROL_TASK_DIR"/.reprovision-stage.* \
      "$CONTROL_TASK_DIR"/.reprovision-backup.* "$TASK_PHYS"/.reprovision-stage.*; do
      [[ -e "$RECOVERY_DIR" || -L "$RECOVERY_DIR" ]] || continue
      [[ -d "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] || fail "reprovision recovery artifact is unsafe: $RECOVERY_DIR"
      rm -rf -- "$RECOVERY_DIR"
    done
    rm -f -- "$REPROVISION_INTENT"
    durable_fsync_paths "$CONTROL_TASK_DIR" "$TASK_PHYS" || fail "could not sync recovered reprovision completion"
    if [[ "${ORC_REPROVISION_TEST_FAIL_AFTER_INTENT_REMOVAL_RECOVERY:-}" == 1 ]]; then
      fail "injected interruption after recovered reprovision intent removal"
    fi
    release_lock || fail "could not release coordinator mutation lock"
    trap - EXIT HUP INT TERM
    echo "reconciled $BRANCH generation $INTENT_NEW_GENERATION at $INTENT_NEW_BASE in $WORKTREE_PHYS"
    exit 0
  fi
  cmp -s "$CONTROL_MANIFEST" "$WORKER_MANIFEST" || fail "retained coordinator and worker manifests differ"

  OLD_WORKTREE=""; OLD_BRANCH=""; OLD_BASE=""; OLD_REPO=""; OLD_EXTRA=""
  IFS=$'\t' read -r OLD_WORKTREE OLD_BRANCH OLD_BASE OLD_REPO OLD_EXTRA < "$CONTROL_MANIFEST" || fail "retained coordinator manifest cannot be read"
  [[ -n "$OLD_WORKTREE" && -n "$OLD_BRANCH" && -n "$OLD_BASE" && -n "$OLD_REPO" && -z "$OLD_EXTRA" && \
    "$(wc -l < "$CONTROL_MANIFEST" | tr -d ' ')" == 1 ]] || fail "retained coordinator manifest is malformed"
  [[ "$OLD_WORKTREE" == "$WORKTREE_PHYS" && "$OLD_BRANCH" == "$BRANCH" && "$OLD_REPO" == "$REPO_PHYS" ]] || fail "reprovision arguments differ from retained exact authority"
  [[ "$PARENT_TIP" != "$OLD_BASE" ]] || fail "reprovision requires an updated parent tip"
  git -C "$REPO_PHYS" rev-parse --verify "${OLD_BASE}^{commit}" >/dev/null 2>&1 || fail "retained base does not resolve"
  git -C "$REPO_PHYS" merge-base --is-ancestor "$OLD_BASE" "$PARENT_TIP" || fail "updated parent does not descend from retained base"
  [[ ! -e "$WORKTREE_PHYS" && ! -L "$WORKTREE_PHYS" ]] || fail "old child worktree still exists"
  ! git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxq "worktree $WORKTREE_PHYS" || fail "old child worktree remains registered"
  ! git -C "$REPO_PHYS" show-ref --verify --quiet "refs/heads/$BRANCH" || fail "old child local branch still exists"

  THREAD_ID_FILE="$CONTROL_TASK_DIR/accepted-thread-id"
  WORKER_THREAD_ID_FILE="$TASK_PHYS/accepted-thread-id"
  THREAD_STATE_FILE="$CONTROL_TASK_DIR/task-window-state"
  for AUTHORITY_FILE in "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" \
    "$WORKER_SANDBOX" "$CONTROL_STATE" "$WORKER_STATE" "$THREAD_ID_FILE" \
    "$WORKER_THREAD_ID_FILE" "$THREAD_STATE_FILE"; do
    [[ -f "$AUTHORITY_FILE" && ! -L "$AUTHORITY_FILE" ]] || fail "retained authority file is missing or unsafe: $AUTHORITY_FILE"
    [[ "$(wc -l < "$AUTHORITY_FILE" | tr -d ' ')" == 1 ]] || fail "retained authority file is malformed: $AUTHORITY_FILE"
  done
  CURRENT_GENERATION="$(tr -d '[:space:]' < "$CONTROL_GENERATION")"
  WORKER_CURRENT_GENERATION="$(tr -d '[:space:]' < "$WORKER_GENERATION")"
  [[ "$CURRENT_GENERATION" == "$EXPECTED_GENERATION" && "$WORKER_CURRENT_GENERATION" == "$EXPECTED_GENERATION" ]] || fail "expected generation does not match retained authority"
  case "$CURRENT_GENERATION" in ''|*[!0-9]*|0) fail "retained generation is invalid" ;; esac
  CONTROL_SANDBOX_VALUE="$(tr -d '\n' < "$CONTROL_SANDBOX")"
  WORKER_SANDBOX_VALUE="$(tr -d '\n' < "$WORKER_SANDBOX")"
  [[ "$CONTROL_SANDBOX_VALUE" == "$WORKTREE_PHYS" && "$WORKER_SANDBOX_VALUE" == "$WORKTREE_PHYS" ]] || fail "reprovision sandbox root differs from retained authority"
  CONTROL_STATE_VALUE="$(tr -d '[:space:]' < "$CONTROL_STATE")"
  WORKER_STATE_VALUE="$(tr -d '[:space:]' < "$WORKER_STATE")"
  case "$CONTROL_STATE_VALUE" in integrated|collected) ;; *) fail "reprovision requires terminal integrated or collected state" ;; esac
  case "$WORKER_STATE_VALUE" in integrated|collected) ;; *) fail "worker task state is not terminal integrated or collected" ;; esac
  ACCEPTED_THREAD_ID="$(tr -d '\n' < "$THREAD_ID_FILE")"
  WORKER_ACCEPTED_THREAD_ID="$(tr -d '\n' < "$WORKER_THREAD_ID_FILE")"
  [[ -n "$ACCEPTED_THREAD_ID" ]] || fail "accepted child thread identity is empty"
  [[ "$WORKER_ACCEPTED_THREAD_ID" == "$ACCEPTED_THREAD_ID" ]] || fail "worker accepted child thread identity differs"
  case "$ACCEPTED_THREAD_ID" in *$'\t'*|*$'\r'*) fail "accepted child thread identity is malformed" ;; esac
  [[ "$(tr -d '[:space:]' < "$THREAD_STATE_FILE")" == unarchived ]] || fail "accepted child thread must be unarchived before reprovision"

  NEXT_GENERATION=$((CURRENT_GENERATION + 1))
  [[ ! -e "$REPROVISION_INTENT" && ! -L "$REPROVISION_INTENT" ]] || fail "reprovision intent already exists"
  REPROVISION_INTENT_TMP="$(mktemp "$CONTROL_TASK_DIR/.reprovision-intent.XXXXXX")" || fail "cannot stage reprovision intent"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CURRENT_GENERATION" "$NEXT_GENERATION" \
    "$OLD_BASE" "$PARENT_TIP" "$WORKTREE_PHYS" "$BRANCH" "$ACCEPTED_THREAD_ID" > "$REPROVISION_INTENT_TMP"
  chmod 0600 "$REPROVISION_INTENT_TMP"
  durable_fsync_paths "$REPROVISION_INTENT_TMP" || fail "could not sync reprovision intent contents"
  if ! ln "$REPROVISION_INTENT_TMP" "$REPROVISION_INTENT" 2>/dev/null; then
    rm -f -- "$REPROVISION_INTENT_TMP"
    fail "reprovision intent publication raced"
  fi
  durable_fsync_paths "$CONTROL_TASK_DIR" || fail "could not sync reprovision intent publication"
  rm -f -- "$REPROVISION_INTENT_TMP"

  REPROVISION_STAGE_DIR="$(mktemp -d "$CONTROL_TASK_DIR/.reprovision-stage.XXXXXX")" || fail "cannot stage reprovision authority"
  REPROVISION_WORKER_STAGE_DIR="$(mktemp -d "$TASK_PHYS/.reprovision-stage.XXXXXX")" || fail "cannot stage worker authority"
  REPROVISION_BACKUP_DIR="$(mktemp -d "$CONTROL_TASK_DIR/.reprovision-backup.XXXXXX")" || fail "cannot stage authority backup"
  printf '%s\t%s\t%s\t%s\n' "$WORKTREE_PHYS" "$BRANCH" "$PARENT_TIP" "$REPO_PHYS" > "$REPROVISION_STAGE_DIR/worktrees.txt"
  cp "$REPROVISION_STAGE_DIR/worktrees.txt" "$REPROVISION_WORKER_STAGE_DIR/worktrees.txt"
  printf '%s\n' "$NEXT_GENERATION" > "$REPROVISION_STAGE_DIR/generation"
  cp "$REPROVISION_STAGE_DIR/generation" "$REPROVISION_WORKER_STAGE_DIR/generation"
  printf '%s\n' "$WORKTREE_PHYS" > "$REPROVISION_STAGE_DIR/sandbox-root"
  cp "$REPROVISION_STAGE_DIR/sandbox-root" "$REPROVISION_WORKER_STAGE_DIR/sandbox-root"
  printf 'ready\n' > "$REPROVISION_STAGE_DIR/state"
  cp "$REPROVISION_STAGE_DIR/state" "$REPROVISION_WORKER_STAGE_DIR/state"
  chmod 0600 "$REPROVISION_STAGE_DIR"/* "$REPROVISION_WORKER_STAGE_DIR"/*
  cp "$CONTROL_MANIFEST" "$REPROVISION_BACKUP_DIR/control-worktrees.txt"
  cp "$WORKER_MANIFEST" "$REPROVISION_BACKUP_DIR/worker-worktrees.txt"
  cp "$CONTROL_GENERATION" "$REPROVISION_BACKUP_DIR/control-generation"
  cp "$WORKER_GENERATION" "$REPROVISION_BACKUP_DIR/worker-generation"
  cp "$CONTROL_SANDBOX" "$REPROVISION_BACKUP_DIR/control-sandbox-root"
  cp "$WORKER_SANDBOX" "$REPROVISION_BACKUP_DIR/worker-sandbox-root"
  cp "$CONTROL_STATE" "$REPROVISION_BACKUP_DIR/control-state"
  cp "$WORKER_STATE" "$REPROVISION_BACKUP_DIR/worker-state"
  chmod 0600 "$REPROVISION_BACKUP_DIR"/*
  ORC_REPROVISION_FSYNC_PHASE=authority durable_fsync_paths \
    "$REPROVISION_STAGE_DIR"/* "$REPROVISION_WORKER_STAGE_DIR"/* \
    "$REPROVISION_BACKUP_DIR"/* "$REPROVISION_STAGE_DIR" \
    "$REPROVISION_WORKER_STAGE_DIR" "$REPROVISION_BACKUP_DIR" || \
    fail "could not sync reprovision staging and backups"

  if ! git -C "$REPO_PHYS" worktree add -q -b "$BRANCH" "$WORKTREE_PHYS" "$PARENT_TIP"; then
    rm -f -- "$REPROVISION_INTENT"
    rm -rf -- "$REPROVISION_STAGE_DIR" "$REPROVISION_WORKER_STAGE_DIR" "$REPROVISION_BACKUP_DIR"
    fail "reprovision could not create the exact child worktree"
  fi
  if ! guarded_replace_batch \
      "$REPROVISION_STAGE_DIR/worktrees.txt" "$CONTROL_MANIFEST" \
      "$REPROVISION_WORKER_STAGE_DIR/worktrees.txt" "$WORKER_MANIFEST" \
      "$REPROVISION_STAGE_DIR/generation" "$CONTROL_GENERATION" \
      "$REPROVISION_WORKER_STAGE_DIR/generation" "$WORKER_GENERATION" \
      "$REPROVISION_STAGE_DIR/sandbox-root" "$CONTROL_SANDBOX" \
      "$REPROVISION_WORKER_STAGE_DIR/sandbox-root" "$WORKER_SANDBOX" \
      "$REPROVISION_STAGE_DIR/state" "$CONTROL_STATE" \
      "$REPROVISION_WORKER_STAGE_DIR/state" "$WORKER_STATE"; then
    RESTORE_SUCCEEDED=0
    if ORC_REPROVISION_RESTORE=1 guarded_replace_batch \
      "$REPROVISION_BACKUP_DIR/control-worktrees.txt" "$CONTROL_MANIFEST" \
      "$REPROVISION_BACKUP_DIR/worker-worktrees.txt" "$WORKER_MANIFEST" \
      "$REPROVISION_BACKUP_DIR/control-generation" "$CONTROL_GENERATION" \
      "$REPROVISION_BACKUP_DIR/worker-generation" "$WORKER_GENERATION" \
      "$REPROVISION_BACKUP_DIR/control-sandbox-root" "$CONTROL_SANDBOX" \
      "$REPROVISION_BACKUP_DIR/worker-sandbox-root" "$WORKER_SANDBOX" \
      "$REPROVISION_BACKUP_DIR/control-state" "$CONTROL_STATE" \
      "$REPROVISION_BACKUP_DIR/worker-state" "$WORKER_STATE" >/dev/null 2>&1; then
      RESTORE_SUCCEEDED=1
    fi
    if [[ "$RESTORE_SUCCEEDED" -eq 1 ]]; then
      if [[ -d "$WORKTREE_PHYS" && -z "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" && \
        "$(git -C "$WORKTREE_PHYS" rev-parse HEAD 2>/dev/null || true)" == "$PARENT_TIP" ]]; then
        git -C "$REPO_PHYS" worktree remove --force "$WORKTREE_PHYS" >/dev/null 2>&1 || true
        git -C "$REPO_PHYS" update-ref -d "refs/heads/$BRANCH" "$PARENT_TIP" >/dev/null 2>&1 || true
      fi
      rm -f -- "$REPROVISION_INTENT"
      rm -rf -- "$REPROVISION_STAGE_DIR" "$REPROVISION_WORKER_STAGE_DIR" "$REPROVISION_BACKUP_DIR"
      fail "reprovision authority publication failed and was rolled back"
    fi
    fail "reprovision authority publication and rollback were incomplete; durable recovery evidence preserved"
  fi
  publish_reprovision_completion "$REPROVISION_COMPLETION" "$CURRENT_GENERATION" \
    "$NEXT_GENERATION" "$OLD_BASE" "$PARENT_TIP" || \
    fail "could not publish reprovision completion receipt"
  rm -f -- "$REPROVISION_INTENT"
  durable_fsync_paths "$CONTROL_TASK_DIR" || fail "could not sync reprovision completion acknowledgement"
  if [[ "${ORC_REPROVISION_TEST_FAIL_AFTER_INTENT_REMOVAL_NORMAL:-}" == 1 ]]; then
    fail "injected interruption after normal reprovision intent removal"
  fi
  rm -rf -- "$REPROVISION_STAGE_DIR" "$REPROVISION_WORKER_STAGE_DIR" "$REPROVISION_BACKUP_DIR"
  durable_fsync_paths "$CONTROL_TASK_DIR" "$TASK_PHYS" || fail "could not sync reprovision artifact cleanup"
  release_lock || fail "could not release coordinator mutation lock"
  trap - EXIT HUP INT TERM
  echo "reprovisioned $BRANCH generation $NEXT_GENERATION at $PARENT_TIP in $WORKTREE_PHYS"
  exit 0
fi

[[ ! -e "$CONTROL_MANIFEST" ]] || fail "task already has a coordinator manifest: $TASK_ID"
[[ ! -e "$WORKER_MANIFEST" && ! -L "$WORKER_MANIFEST" ]] || fail "task already has a worker manifest: $TASK_ID"
for NEW_AUTHORITY_PATH in "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" \
  "$WORKER_SANDBOX" "$CONTROL_STATE" "$WORKER_STATE"; do
  [[ ! -e "$NEW_AUTHORITY_PATH" && ! -L "$NEW_AUTHORITY_PATH" ]] || fail "task already has retained authority: $NEW_AUTHORITY_PATH"
done
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
    if ! cleanup_new_authority; then
      echo "task-worktree: rollback preserved changed retained authority" >&2
      manifest_cleanup_ok=0
    fi
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
publish_new_authority "$CONTROL_GENERATION" 1 || fail "could not publish coordinator generation authority"
publish_new_authority "$WORKER_GENERATION" 1 || fail "could not publish worker generation authority"
publish_new_authority "$CONTROL_SANDBOX" "$WORKTREE_PHYS" || fail "could not publish coordinator sandbox authority"
publish_new_authority "$WORKER_SANDBOX" "$WORKTREE_PHYS" || fail "could not publish worker sandbox authority"
publish_new_authority "$CONTROL_STATE" ready || fail "could not publish coordinator task state"
publish_new_authority "$WORKER_STATE" ready || fail "could not publish worker task state"
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
finalize_new_authority || fail "could not finalize retained task authority"
release_lock || fail "could not release coordinator mutation lock"
trap - EXIT HUP INT TERM
echo "created $BRANCH at $PARENT_TIP in $WORKTREE_PHYS"
