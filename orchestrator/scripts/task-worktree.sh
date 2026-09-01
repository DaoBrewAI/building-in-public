#!/usr/bin/env bash
# Create or adopt one coordinator-owned child task worktree.

set -euo pipefail

LOCK_FILE=""
LOCK_CANDIDATE=""
LOCK_TOKEN=""
LOCK_OWNED=0
LOCK_CANDIDATE_OWNED=0
LOCK_PUBLISH_INTENT=0
GUARD_DIR=""
GUARD_TOKEN=""
GUARD_OWNED=0
NEW_AUTHORITY_DESTS=()
NEW_AUTHORITY_TEMPS=()

usage() {
  echo "usage: task-worktree.sh create --create-mode test-fixture --mission-dir <dir> --control-dir <dir> --task-dir <dir> --mission <slug> --task-id <id> --repo <repo> --parent-worktree <dir> --worktree <dir>" >&2
  echo "       task-worktree.sh adopt --mission-dir <dir> --control-dir <dir> --task-dir <dir> --mission <slug> --task-id <id> --repo <repo> --parent-worktree <dir> --worktree <native-worktree> --thread-id <id>" >&2
}

NATIVE_HEALTH_HELPER="$(cd "$(dirname "$0")" && pwd -P)/native-task-health.py"

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
  if [[ "${ORC_TASK_WORKTREE_TEST_FAIL_FINALIZE:-}" == 1 ]]; then
    return 1
  fi
  durable_fsync_paths "$@" "${NEW_AUTHORITY_DESTS[@]}"
}

discard_new_authority_temps() {
  local temporary ok=1
  for temporary in "${NEW_AUTHORITY_TEMPS[@]}"; do
    rm -f -- "$temporary" || ok=0
  done
  NEW_AUTHORITY_DESTS=()
  NEW_AUTHORITY_TEMPS=()
  [[ "$ok" -eq 1 ]]
}

lifecycle_guard_operation() {
  python3 - "$1" "$GUARD_DIR" "$$" "$GUARD_TOKEN" <<'PY'
import os, re, stat, sys
operation, guard, pid, token = sys.argv[1:]
expected = (pid + "\t" + token + "\n").encode("ascii")
parent = os.path.dirname(guard) or "."
candidate = guard + ".candidate." + pid + "." + token
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
def syncdir(path):
    fd=os.open(path,flags)
    try: os.fsync(fd)
    finally: os.close(fd)
def prepare():
    if os.path.lexists(candidate): raise SystemExit(1)
    os.mkdir(candidate,0o700)
    d=os.open(candidate,flags)
    try:
        f=os.open("owner",os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600,dir_fd=d)
        try:
            if os.write(f,expected)!=len(expected): raise OSError("short guard write")
            os.fsync(f)
        finally: os.close(f)
        os.fsync(d)
    finally: os.close(d)
    syncdir(parent)
def publish():
    os.rename(candidate,guard)
    syncdir(parent)
def cleanup_candidate():
    if not os.path.lexists(candidate): return
    d=os.open(candidate,flags)
    try:
        if owner(d)!=expected: raise SystemExit(1)
        os.unlink("owner",dir_fd=d); os.fsync(d)
    finally: os.close(d)
    os.rmdir(candidate); syncdir(parent)
def opened():
    before=os.lstat(guard)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode): raise SystemExit(1)
    d=os.open(guard,flags); now=os.fstat(d); current=os.lstat(guard)
    if (now.st_dev,now.st_ino)!=(before.st_dev,before.st_ino) or (current.st_dev,current.st_ino)!=(before.st_dev,before.st_ino):
        os.close(d); raise SystemExit(1)
    return d,before
def owner(d):
    f=os.open("owner",os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=d)
    try:
        before=os.fstat(f)
        if not stat.S_ISREG(before.st_mode) or before.st_size>512: raise SystemExit(1)
        data=os.read(f,513); after=os.fstat(f)
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns): raise SystemExit(1)
        return data
    finally: os.close(f)
def live(value):
    try: os.kill(value,0); return True
    except ProcessLookupError: return False
    except PermissionError: return True
def remove(d,before):
    os.unlink("owner",dir_fd=d); os.fsync(d)
    current=os.lstat(guard)
    if (current.st_dev,current.st_ino)!=(before.st_dev,before.st_ino): raise SystemExit(1)
    os.rmdir(guard); syncdir(parent)
if operation=="acquire":
    try:
        prepare()
        if not os.path.lexists(guard):
            try: publish(); raise SystemExit(0)
            except OSError:
                if not os.path.lexists(guard): raise
        d,before=opened()
        try:
            try: data=owner(d)
            except FileNotFoundError:
                if os.listdir(d): raise SystemExit(1)
                current=os.lstat(guard)
                if (current.st_dev,current.st_ino)!=(before.st_dev,before.st_ino): raise SystemExit(1)
                os.rmdir(guard); syncdir(parent)
            else:
                try: p,t=data.decode("ascii").rstrip("\n").split("\t")
                except Exception: raise SystemExit(1)
                if (data!=(p+"\t"+t+"\n").encode("ascii") or not p.isdigit() or
                        not re.fullmatch(r"[A-Za-z0-9._-]+",t) or live(int(p))): raise SystemExit(1)
                remove(d,before)
        finally: os.close(d)
        try: publish()
        except OSError: raise SystemExit(1)
    finally:
        cleanup_candidate()
elif operation=="release":
    d,before=opened()
    try:
        if owner(d)!=expected: raise SystemExit(1)
        remove(d,before)
    finally: os.close(d)
else: raise SystemExit(1)
PY
}

acquire_lifecycle_guard() {
  GUARD_DIR="$LOCK_FILE.guard"
  GUARD_TOKEN="$RANDOM.$(date +%s).guard"
  lifecycle_guard_operation acquire || return 1
  GUARD_OWNED=1
}

release_lifecycle_guard() {
  [[ "$GUARD_OWNED" -eq 1 ]] || return 0
  lifecycle_guard_operation release || return 1
  GUARD_OWNED=0
}

release_lock() {
  local release_ok=1
  if [[ "$GUARD_OWNED" -eq 0 && ( "$LOCK_PUBLISH_INTENT" -eq 1 || "$LOCK_CANDIDATE_OWNED" -eq 1 ) ]]; then
    acquire_lifecycle_guard || return 1
  fi
  if [[ "$LOCK_PUBLISH_INTENT" -eq 1 ]]; then
    if [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" && -f "$LOCK_CANDIDATE" && ! -L "$LOCK_CANDIDATE" && "$LOCK_FILE" -ef "$LOCK_CANDIDATE" ]]; then
      if ! guarded_remove_stale_lock "$LOCK_CANDIDATE" "$$" "$LOCK_TOKEN"; then
        echo "task-worktree: coordinator lock release failed" >&2
        release_ok=0
      else
        LOCK_OWNED=0
        LOCK_PUBLISH_INTENT=0
        LOCK_CANDIDATE_OWNED=0
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
  release_lifecycle_guard || release_ok=0
  [[ "$release_ok" -eq 1 ]]
}

pid_is_live() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'
}

guarded_remove_stale_lock() {
  local stale_candidate="$1" stale_pid="$2" stale_token="$3"
  python3 - "$LOCK_FILE" "$stale_candidate" "$stale_pid" "$stale_token" <<'PY'
import os
import stat
import sys

lock_path, candidate_path, stale_pid, stale_token = sys.argv[1:]

def snapshot(path):
    before = os.lstat(path)
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode) or
            before.st_size > 512):
        raise SystemExit(1)
    metadata = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                              value.st_nlink, value.st_uid, value.st_gid,
                              value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if metadata(opened) != metadata(before):
            raise SystemExit(1)
        data = os.read(descriptor, 513)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = os.lstat(path)
    if metadata(after) != metadata(before) or metadata(current) != metadata(before):
        raise SystemExit(1)
    return metadata(before) + (data,)

lock_snapshot = snapshot(lock_path)
candidate_snapshot = snapshot(candidate_path)
if lock_snapshot != candidate_snapshot:
    raise SystemExit(1)
if lock_snapshot[-1] != (stale_pid + "\t" + stale_token + "\n").encode("ascii"):
    raise SystemExit(1)

# Deterministic test hook: atomically publish a different, correctly linked
# owner between the stale snapshot and the destructive boundary.
replacement = os.environ.get("ORC_STALE_LOCK_TEST_REPLACEMENT")
marker = os.environ.get("ORC_STALE_LOCK_TEST_MARKER")
if replacement:
    snapshot(replacement)
    os.replace(replacement, lock_path)
    if marker:
        with open(marker, "wb") as handle:
            handle.write(b"replaced\n")
            handle.flush()
            os.fsync(handle.fileno())
    directory_fd = os.open(os.path.dirname(lock_path) or ".", os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

if snapshot(lock_path) != lock_snapshot or snapshot(candidate_path) != candidate_snapshot:
    raise SystemExit(1)

final_replacement = os.environ.get("ORC_STALE_LOCK_TEST_FINAL_REPLACEMENT")
if final_replacement:
    snapshot(final_replacement)
    os.replace(final_replacement, lock_path)
    if marker:
        with open(marker, "wb") as handle:
            handle.write(b"final-replaced\n")
            handle.flush()
            os.fsync(handle.fileno())

quarantine = lock_path + ".recovery." + str(os.getpid()) + "." + os.urandom(8).hex()
if os.path.lexists(quarantine):
    raise SystemExit(1)
os.rename(lock_path, quarantine)
quarantine_snapshot = snapshot(quarantine)
stable_fields = (0, 1, 2, 4, 5, 6, 7, 9)
same_epoch = lambda left, right: tuple(left[index] for index in stable_fields) == tuple(
    right[index] for index in stable_fields)
if not same_epoch(quarantine_snapshot, lock_snapshot):
    try:
        os.link(quarantine, lock_path)
    except FileExistsError:
        raise SystemExit(1)
    restored = snapshot(lock_path)
    quarantined_after_link = snapshot(quarantine)
    if not same_epoch(restored, quarantine_snapshot) or not same_epoch(
            quarantined_after_link, quarantine_snapshot):
        raise SystemExit(1)
    os.unlink(quarantine)
    directory_fd = os.open(os.path.dirname(lock_path) or ".", os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    raise SystemExit(1)
candidate_quarantined = snapshot(candidate_path)
if not same_epoch(candidate_quarantined, candidate_snapshot):
    raise SystemExit(1)
if snapshot(quarantine) != quarantine_snapshot or snapshot(candidate_path) != candidate_quarantined:
    raise SystemExit(1)
os.unlink(quarantine)
candidate_after_quarantine = snapshot(candidate_path)
if not same_epoch(candidate_after_quarantine, candidate_snapshot):
    raise SystemExit(1)
if snapshot(candidate_path) != candidate_after_quarantine:
    raise SystemExit(1)
os.unlink(candidate_path)
directory_fd = os.open(os.path.dirname(lock_path) or ".", os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

verify_native_create_ready() {
  local classifier approval_helper classification tasks_initialized=0 dag_json
  classifier="$(cd "$(dirname "$0")" && pwd -P)/classify-mission-version.sh"
  approval_helper="$(cd "$(dirname "$0")" && pwd -P)/verify-approved-authority.py"
  [[ -x "$approval_helper" && -x "$classifier" ]] || fail "native scheduling helpers are unavailable"
  dag_json="$("$approval_helper" --control-dir "$CONTROL_PHYS" --dag-json)" || fail "frozen approval authority is invalid"

  python3 - "$MISSION_DIR_PHYS" "$CONTROL_PHYS" "$TASK_ID" "$dag_json" <<'PY'
import json
import os
import stat
import sys

mission, control, task_id, dag_raw = sys.argv[1:]

def regular(path):
    value = os.lstat(path)
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
        raise ValueError(path)
    return value

dag = json.loads(dag_raw)
nodes = {node["id"]: node for node in dag["tasks"]}
if task_id not in nodes:
    raise SystemExit("requested task is not an exact approved DAG node")
node = nodes[task_id]
if node.get("state") not in ("pending", "ready"):
    raise SystemExit("requested task is not schedulable")

tasks_root = os.path.join(control, "tasks")
if os.path.lexists(tasks_root):
    root_stat = os.lstat(tasks_root)
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise SystemExit("task authority root is unsafe")

def task_dir(identifier):
    path = os.path.join(tasks_root, identifier)
    if os.path.lexists(path):
        value = os.lstat(path)
        if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
            raise SystemExit("task authority path is unsafe")
    return path

def authority_value(path):
    regular(path)
    with open(path, "r", encoding="utf-8", newline="") as handle:
        value = handle.read()
    if not value.endswith("\n") or value.count("\n") != 1:
        raise SystemExit("task authority is malformed")
    return value[:-1]

for predecessor in node.get("depends_on", []):
    predecessor_dir = task_dir(predecessor)
    if authority_value(os.path.join(predecessor_dir, "state")) not in ("integrated", "collected"):
        raise SystemExit("predecessor is not integrated or collected")
    if os.path.lexists(os.path.join(predecessor_dir, "unresolved-rework")):
        raise SystemExit("predecessor has unresolved rework")

requested_dir = task_dir(task_id)
for blocker in ("accepted-thread-id", "user-approval-blocker", "unresolved-rework"):
    if os.path.lexists(os.path.join(requested_dir, blocker)):
        raise SystemExit("requested task has an unresolved owner or approval blocker")

requested_files = set(node.get("files", []))
requested_contracts = set(node.get("contracts", []))
active_states = {
    "pending", "ready", "running", "ready_for_commit", "blocked", "failed",
    "review", "rework", "completed", "cleanup_pending",
}
for other_id, other in nodes.items():
    if other_id == task_id:
        continue
    other_dir = task_dir(other_id)
    state_path = os.path.join(other_dir, "state")
    if not os.path.lexists(state_path):
        continue
    state = authority_value(state_path)
    if state not in active_states:
        continue
    if requested_files.intersection(other.get("files", [])) or requested_contracts.intersection(other.get("contracts", [])):
        raise SystemExit("requested task conflicts with another active DAG node")
PY
  if [[ ! -e "$CONTROL_PHYS/tasks" && ! -L "$CONTROL_PHYS/tasks" ]]; then
    mkdir "$CONTROL_PHYS/tasks" || fail "cannot initialize native task authority root"
    durable_fsync_paths "$CONTROL_PHYS/tasks" || fail "cannot sync native task authority root"
    tasks_initialized=1
  fi
  if ! classification="$($classifier --mission-dir "$MISSION_DIR_PHYS" --control-dir "$CONTROL_PHYS")"; then
    if [[ "$tasks_initialized" -eq 1 ]]; then
      rmdir "$CONTROL_PHYS/tasks" 2>/dev/null || true
      durable_fsync_paths "$CONTROL_PHYS" >/dev/null 2>&1 || true
    fi
    fail "mission authority cannot be classified"
  fi
  if [[ "$classification" != native-0.4 ]]; then
    if [[ "$tasks_initialized" -eq 1 ]]; then
      rmdir "$CONTROL_PHYS/tasks" 2>/dev/null || true
      durable_fsync_paths "$CONTROL_PHYS" >/dev/null 2>&1 || true
    fi
    fail "create requires validated native 0.4 authority"
  fi
}

acquire_lock() {
  local stale_pid=""
  local stale_token=""
  local stale_extra=""
  local stale_candidate=""
  local candidate_pid=""
  local candidate_token=""
  local candidate_extra=""

  acquire_lifecycle_guard || fail "coordinator lifecycle guard is unsafe or busy"
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
    release_lifecycle_guard || fail "coordinator lifecycle guard release failed"
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
  guarded_remove_stale_lock "$stale_candidate" "$stale_pid" "$stale_token" || fail "stale coordinator lock changed during reconciliation"

  LOCK_PUBLISH_INTENT=1
  if ! ln "$LOCK_CANDIDATE" "$LOCK_FILE" 2>/dev/null; then
    fail "coordinator mutation lock contention persisted"
  fi
  [[ "$LOCK_FILE" -ef "$LOCK_CANDIDATE" ]] || fail "coordinator lock publication could not be verified"
  LOCK_OWNED=1
  release_lifecycle_guard || fail "coordinator lifecycle guard release failed"
}

lock_exit() {
  local original_rc="$1"
  trap - EXIT HUP INT TERM
  release_lock || true
  exit "$original_rc"
}

MODE="${1:-}"
case "$MODE" in
  create|adopt) ;;
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
MISSION_DIR=""
CREATE_MODE=""
THREAD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; CONTROL_DIR="$2"; shift 2 ;;
    --task-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_DIR="$2"; shift 2 ;;
    --mission) [[ $# -ge 2 ]] || { usage; exit 1; }; MISSION="$2"; shift 2 ;;
    --task-id) [[ $# -ge 2 ]] || { usage; exit 1; }; TASK_ID="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { usage; exit 1; }; REPO="$2"; shift 2 ;;
    --parent-worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; PARENT_WORKTREE="$2"; shift 2 ;;
    --worktree) [[ $# -ge 2 ]] || { usage; exit 1; }; WORKTREE="$2"; shift 2 ;;
    --mission-dir) [[ $# -ge 2 ]] || { usage; exit 1; }; MISSION_DIR="$2"; shift 2 ;;
    --create-mode) [[ $# -ge 2 ]] || { usage; exit 1; }; CREATE_MODE="$2"; shift 2 ;;
    --thread-id) [[ $# -ge 2 ]] || { usage; exit 1; }; THREAD_ID="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$MISSION_DIR" ]] || fail "$MODE requires a mission directory"
if [[ "$MODE" == create ]]; then
  [[ "$CREATE_MODE" == test-fixture ]] || fail "direct child creation is test-fixture only; production requires app-native health plus adopt"
  [[ -z "$THREAD_ID" ]] || fail "create does not accept native adoption authority"
else
  case "$CREATE_MODE" in ''|test-fixture) ;; *) fail "unsupported adopt mode: $CREATE_MODE" ;; esac
  valid_identity "$THREAD_ID" || fail "adopt requires a valid native thread id"
fi

for VALUE in "$CONTROL_DIR" "$TASK_DIR" "$MISSION" "$TASK_ID" "$REPO" "$PARENT_WORKTREE" "$WORKTREE"; do
  [[ -n "$VALUE" ]] || { usage; exit 1; }
done
valid_identity "$MISSION" || fail "invalid mission identity"
valid_identity "$TASK_ID" || fail "invalid task identity"

for PATH_VALUE in "$CONTROL_DIR" "$TASK_DIR" "$REPO" "$PARENT_WORKTREE" "$WORKTREE" ${MISSION_DIR:+"$MISSION_DIR"}; do
  absolute_path "$PATH_VALUE" || fail "paths must be absolute"
  case "$PATH_VALUE" in
    *$'\t'*|*$'\n'*|*$'\r'*) fail "paths may not contain tabs or newlines" ;;
    */./*|*/../*|*/.|*/..) fail "paths may not contain dot components" ;;
  esac
done

[[ -d "$CONTROL_DIR" && ! -L "$CONTROL_DIR" ]] || fail "control directory missing or symlinked: $CONTROL_DIR"
if [[ "$MODE" == create || "$MODE" == adopt ]]; then
  [[ -d "$MISSION_DIR" && ! -L "$MISSION_DIR" ]] || fail "mission directory missing or symlinked: $MISSION_DIR"
  MISSION_DIR_PHYS="$(cd "$MISSION_DIR" && pwd -P)"
fi
[[ -d "$REPO" && ! -L "$REPO" ]] || fail "repository missing or symlinked: $REPO"
[[ -d "$PARENT_WORKTREE" && ! -L "$PARENT_WORKTREE" ]] || fail "parent worktree missing or symlinked: $PARENT_WORKTREE"
if [[ -e "$WORKTREE" || -L "$WORKTREE" ]]; then
  [[ "$MODE" == adopt && -d "$WORKTREE" && ! -L "$WORKTREE" ]] || fail "child worktree already exists: $WORKTREE"
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
LIVE_PARENT_TIP="$PARENT_TIP"
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

if [[ "$MODE" == create || "$MODE" == adopt ]]; then
  if [[ "$CREATE_MODE" == test-fixture ]]; then
    [[ "${ORC_TASK_WORKTREE_TESTING:-}" == 1 ]] || fail "test fixture mode is disabled"
    TEST_ROOT="${ORC_TASK_WORKTREE_TEST_FIXTURE_ROOT:-}"
    [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]] || fail "test fixture root is unavailable"
    TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
    case "$TEST_ROOT" in
      /private/tmp/*|/tmp/*|/private/var/folders/*) ;;
      *) fail "test fixture root must be inside a system temporary directory" ;;
    esac
    for TEST_PATH in "$CONTROL_PHYS" "$TASK_PHYS" "$REPO_PHYS" "$PARENT_PHYS" "$WORKTREE_PHYS" "$MISSION_DIR_PHYS"; do
      case "$TEST_PATH" in "$TEST_ROOT"|"$TEST_ROOT"/*) ;; *) fail "test fixture path escapes its root" ;; esac
    done
  else
    verify_native_create_ready
  fi
fi

if [[ "$MODE" == adopt ]]; then
  [[ -x "$NATIVE_HEALTH_HELPER" ]] || fail "native child health helper is unavailable"
  PARENT_TIP="$("$NATIVE_HEALTH_HELPER" verify-adoption \
    --control-dir "$CONTROL_PHYS" --task-dir "$TASK_PHYS" --task-id "$TASK_ID" \
    --thread-id "$THREAD_ID" --repo "$REPO_PHYS" --worktree "$WORKTREE_PHYS" \
    --live-parent-tip "$LIVE_PARENT_TIP")" || fail "accepted native child health cannot be consumed"
  [[ "$PARENT_TIP" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail "native child health returned an invalid schedule base"
fi

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
CONTROL_THREAD="$CONTROL_TASK_DIR/accepted-thread-id"
WORKER_THREAD="$TASK_PHYS/accepted-thread-id"
TASK_WINDOW_STATE="$CONTROL_TASK_DIR/task-window-state"
CONTROL_OUTCOME_NONCE="$CONTROL_TASK_DIR/outcome-nonce"
WORKER_OUTCOME_NONCE="$TASK_PHYS/outcome-nonce"

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
    [[ "$MODE" == adopt && "$WORKTREE_PHYS" == "$GIT_WORKTREE_PHYS" ]] || fail "child worktree overlaps a registered Git worktree"
  fi
  paths_overlap "$TASK_PHYS" "$GIT_WORKTREE_PHYS" && fail "task directory overlaps a registered Git worktree"
  paths_overlap "$CONTROL_MANIFEST_PHYS" "$GIT_WORKTREE_PHYS" && fail "coordinator manifest overlaps a registered Git worktree"
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')

if [[ "$MODE" == adopt ]]; then
  ADOPT_REGISTRATIONS="$(git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxc "worktree $WORKTREE_PHYS" || true)"
  [[ "$ADOPT_REGISTRATIONS" == 1 ]] || fail "native child worktree is not registered exactly once"
  ADOPT_COMMON="$(cd "$WORKTREE_PHYS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" || fail "native child worktree is not Git"
  [[ "$ADOPT_COMMON" == "$REPO_COMMON" ]] || fail "native child worktree belongs to another repository"
  [[ -z "$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ]] || fail "native child worktree must be detached before adoption"
  [[ "$(git -C "$WORKTREE_PHYS" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" == "$PARENT_TIP" ]] || fail "native child worktree is not at the exact parent tip"
  [[ -z "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all)" ]] || fail "native child worktree is dirty before adoption"
fi

[[ ! -e "$CONTROL_MANIFEST" ]] || fail "task already has a coordinator manifest: $TASK_ID"
[[ ! -e "$WORKER_MANIFEST" && ! -L "$WORKER_MANIFEST" ]] || fail "task already has a worker manifest: $TASK_ID"
for NEW_AUTHORITY_PATH in "$CONTROL_GENERATION" "$WORKER_GENERATION" "$CONTROL_SANDBOX" \
  "$WORKER_SANDBOX" "$CONTROL_STATE" "$WORKER_STATE"; do
  [[ ! -e "$NEW_AUTHORITY_PATH" && ! -L "$NEW_AUTHORITY_PATH" ]] || fail "task already has retained authority: $NEW_AUTHORITY_PATH"
done
if [[ "$MODE" == adopt ]]; then
  for NEW_ADOPTION_AUTHORITY in "$CONTROL_THREAD" "$WORKER_THREAD" "$TASK_WINDOW_STATE" "$CONTROL_OUTCOME_NONCE"; do
    [[ ! -e "$NEW_ADOPTION_AUTHORITY" && ! -L "$NEW_ADOPTION_AUTHORITY" ]] || fail "task already has retained adoption authority: $NEW_ADOPTION_AUTHORITY"
  done
  [[ ! -e "$WORKER_OUTCOME_NONCE" && ! -L "$WORKER_OUTCOME_NONCE" ]] || fail "worker task directory must not contain outcome nonce authority"
fi
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
  local child_branch=""
  local registered_child=0
  trap - EXIT
  trap '' HUP INT TERM

  if [[ "$WORKTREE_CREATE_INTENT" -eq 1 ]]; then
    if [[ "$MODE" == adopt ]]; then
      if git -C "$REPO_PHYS" worktree list --porcelain | grep -Fxq "worktree $WORKTREE_PHYS"; then
        registered_child=1
      fi
      branch_tip="$(git -C "$REPO_PHYS" rev-parse --verify "refs/heads/${BRANCH}^{commit}" 2>/dev/null || true)"
      child_common="$(cd "$WORKTREE_PHYS" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
      child_branch="$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      if [[ "$registered_child" -ne 1 || "$child_common" != "$REPO_COMMON" ]] || \
        [[ "$(git -C "$WORKTREE_PHYS" rev-parse --verify HEAD 2>/dev/null || true)" != "$PARENT_TIP" ]] || \
        [[ -n "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
        echo "task-worktree: rollback refused because the adopted child resource changed" >&2
        git_cleanup_ok=0
      elif [[ -z "$child_branch" ]]; then
        if [[ -n "$branch_tip" && "$branch_tip" != "$PARENT_TIP" ]]; then
          echo "task-worktree: rollback preserved changed adopted child branch: $BRANCH" >&2
          git_cleanup_ok=0
        elif [[ "$branch_tip" == "$PARENT_TIP" ]] && ! git -C "$REPO_PHYS" branch -D "$BRANCH" >/dev/null 2>&1; then
          echo "task-worktree: rollback could not remove detached adopted child branch: $BRANCH" >&2
          git_cleanup_ok=0
        fi
      elif [[ "$child_branch" != "$BRANCH" || "$branch_tip" != "$PARENT_TIP" ]]; then
        echo "task-worktree: rollback preserved changed adopted child branch: $BRANCH" >&2
        git_cleanup_ok=0
      elif ! git -C "$WORKTREE_PHYS" switch -q --detach "$PARENT_TIP"; then
          echo "task-worktree: rollback could not detach adopted child worktree" >&2
          git_cleanup_ok=0
      elif ! git -C "$REPO_PHYS" branch -D "$BRANCH" >/dev/null 2>&1; then
          echo "task-worktree: rollback could not remove adopted child branch: $BRANCH" >&2
          git_cleanup_ok=0
      fi
    else
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
if [[ "$MODE" == adopt ]]; then
  OUTCOME_NONCE="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)" || fail "could not generate native task outcome nonce"
  [[ "$OUTCOME_NONCE" =~ ^[0-9a-f]{64}$ ]] || fail "generated native task outcome nonce is invalid"
  publish_new_authority "$CONTROL_THREAD" "$THREAD_ID" || fail "could not publish coordinator native thread authority"
  publish_new_authority "$WORKER_THREAD" "$THREAD_ID" || fail "could not publish worker native thread authority"
  publish_new_authority "$TASK_WINDOW_STATE" unarchived || fail "could not publish native task window authority"
  publish_new_authority "$CONTROL_OUTCOME_NONCE" "$OUTCOME_NONCE" || fail "could not publish native task outcome nonce"
fi
WORKTREE_CREATE_INTENT=1
if [[ "$MODE" == adopt && "${ORC_TASK_WORKTREE_TEST_FAIL_BEFORE_ADOPT:-}" == "1" ]]; then
  fail "injected failure before native child adoption"
fi
if [[ "$MODE" == adopt ]]; then
  git -C "$WORKTREE_PHYS" switch -q -c "$BRANCH" "$PARENT_TIP"
  [[ "$(git -C "$WORKTREE_PHYS" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$BRANCH" && \
    "$(git -C "$WORKTREE_PHYS" rev-parse --verify HEAD 2>/dev/null || true)" == "$PARENT_TIP" && \
    -z "$(git -C "$WORKTREE_PHYS" status --porcelain --untracked-files=all 2>/dev/null || true)" ]] || \
    fail "native child worktree changed during adoption"
else
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WORKTREE_PHYS" "$PARENT_TIP"
fi
WORKTREE_ADDED=1

if [[ "$MODE" == adopt && "${ORC_TASK_WORKTREE_TEST_FAIL_AFTER_ADOPT:-}" == "1" ]]; then
  fail "injected failure after native child adoption"
fi
if [[ "$MODE" == create && "${ORC_TASK_WORKTREE_TEST_FAIL_AFTER_ADD:-}" == "1" ]]; then
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

finalize_new_authority "$CONTROL_MANIFEST" "$WORKER_MANIFEST" || fail "could not durably finalize retained task authority"
trap 'lock_exit "$?"' EXIT
trap 'exit 0' HUP INT TERM
if ! rm -f -- "$WORKER_MANIFEST_TMP"; then
  echo "task-worktree: warning: committed worker manifest temporary link remains" >&2
fi
WORKER_MANIFEST_TMP_OWNED=0
if ! rm -f -- "$MANIFEST_TMP"; then
  echo "task-worktree: warning: committed coordinator manifest temporary link remains" >&2
fi
MANIFEST_TMP_OWNED=0
if ! discard_new_authority_temps; then
  echo "task-worktree: warning: committed authority temporary link remains" >&2
fi
if [[ "$MODE" == adopt ]]; then
  echo "adopted $BRANCH at $PARENT_TIP in $WORKTREE_PHYS"
else
  echo "created $BRANCH at $PARENT_TIP in $WORKTREE_PHYS"
fi
exit 0
