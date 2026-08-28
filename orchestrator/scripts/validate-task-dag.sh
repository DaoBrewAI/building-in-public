#!/usr/bin/env bash
# Validate an approved mission task DAG and optionally freeze it in coordinator control.
set -u

usage() {
  echo "usage: $0 [--freeze] <task-dag.json> [control-dir]" >&2
  exit 2
}

MODE="validate"
if [[ "${1:-}" == "--freeze" ]]; then
  MODE="freeze"
  shift
fi

if [[ "$MODE" == "freeze" ]]; then
  [[ "$#" -eq 2 ]] || usage
else
  [[ "$#" -eq 1 ]] || usage
fi

SOURCE_DAG="$1"
[[ -s "$SOURCE_DAG" && ! -L "$SOURCE_DAG" ]] || {
  echo "task DAG is missing, empty, or symlinked: $SOURCE_DAG" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to validate task DAG JSON" >&2
  exit 1
}

validate_dag() {
  local DAG_PATH="$1"
  python3 - "$DAG_PATH" <<'PY'
import json
import re
import sys
import unicodedata


def reject(message):
    sys.stderr.write("invalid task DAG: %s\n" % message)
    raise SystemExit(1)


path = sys.argv[1]
try:
    with open(path, "r") as handle:
        dag = json.load(handle)
except (IOError, ValueError) as exc:
    reject(str(exc))

if not isinstance(dag, dict):
    reject("root must be an object")
if dag.get("version") != 1:
    reject("version must be 1")
identity_pattern = re.compile(r"\A[A-Za-z0-9._-]+\Z")


def require_identity(value, label):
    if (not isinstance(value, str) or value in (".", "..") or
            identity_pattern.match(value) is None):
        reject("%s must match [A-Za-z0-9._-]+ and may not be . or .." % label)


def require_repo_path(value, task_id):
    if not isinstance(value, str) or not value:
        reject("task %s has an empty or non-string files entry" % task_id)
    if value.startswith("/") or re.match(r"\A[A-Za-z]:", value) or "\\" in value:
        reject("task %s file path must be repo-relative: %s" % (task_id, value))
    segments = value.split("/")
    if any(segment in ("", ".", "..") for segment in segments):
        reject("task %s file path is not canonical: %s" % (task_id, value))
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        reject("task %s file path contains a control character" % task_id)


def file_collision_key(value):
    return unicodedata.normalize("NFC", value).casefold()


require_identity(dag.get("mission"), "mission")
tasks = dag.get("tasks")
if not isinstance(tasks, list) or not tasks:
    reject("tasks must be a non-empty array")

allowed_states = {
    "pending", "ready", "running", "blocked", "failed", "rework", "review",
    "completed", "integrated", "cleanup_pending", "collected",
}
required_arrays = ("depends_on", "files", "contracts", "verification")
by_id = {}

for index, task in enumerate(tasks):
    label = "task at index %d" % index
    if not isinstance(task, dict):
        reject("%s must be an object" % label)
    task_id = task.get("id")
    require_identity(task_id, "%s id" % label)
    if task_id in by_id:
        reject("duplicate task id: %s" % task_id)
    for field in required_arrays:
        value = task.get(field)
        if not isinstance(value, list):
            reject("task %s must declare %s as an array" % (task_id, field))
        if field in ("files", "verification") and not value:
            reject("task %s must declare at least one %s entry" % (task_id, field))
        if any(not isinstance(item, str) or not item.strip() for item in value):
            reject("task %s has an empty or non-string %s entry" % (task_id, field))
        if len(value) != len(set(value)):
            reject("task %s has duplicate %s entries" % (task_id, field))
    for file_path in task["files"]:
        require_repo_path(file_path, task_id)
    file_keys = [file_collision_key(file_path) for file_path in task["files"]]
    if len(file_keys) != len(set(file_keys)):
        reject("task %s has filesystem-equivalent files entries" % task_id)
    state = task.get("state")
    if state not in allowed_states:
        reject("task %s has unknown state: %s" % (task_id, state))
    by_id[task_id] = task

for task_id, task in by_id.items():
    for dependency in task["depends_on"]:
        if dependency not in by_id:
            reject("task %s depends on unknown task %s" % (task_id, dependency))
        if dependency == task_id:
            reject("task %s depends on itself" % task_id)

visiting = set()
visited = set()


def visit(task_id):
    if task_id in visiting:
        reject("dependency cycle includes task %s" % task_id)
    if task_id in visited:
        return
    visiting.add(task_id)
    for dependency in by_id[task_id]["depends_on"]:
        visit(dependency)
    visiting.remove(task_id)
    visited.add(task_id)


for task_id in by_id:
    visit(task_id)


def ancestors(task_id):
    result = set()
    pending = list(by_id[task_id]["depends_on"])
    while pending:
        dependency = pending.pop()
        if dependency in result:
            continue
        result.add(dependency)
        pending.extend(by_id[dependency]["depends_on"])
    return result


ancestor_map = {task_id: ancestors(task_id) for task_id in by_id}
file_key_map = {
    task_id: {file_collision_key(file_path) for file_path in task["files"]}
    for task_id, task in by_id.items()
}
task_ids = list(by_id)
for left_index, left_id in enumerate(task_ids):
    for right_id in task_ids[left_index + 1:]:
        if left_id in ancestor_map[right_id] or right_id in ancestor_map[left_id]:
            continue
        shared_files = file_key_map[left_id] & file_key_map[right_id]
        shared_contracts = set(by_id[left_id]["contracts"]) & set(by_id[right_id]["contracts"])
        if shared_files or shared_contracts:
            details = []
            if shared_files:
                details.append("files %s" % ", ".join(sorted(shared_files)))
            if shared_contracts:
                details.append("contracts %s" % ", ".join(sorted(shared_contracts)))
            reject("parallel-ready tasks %s and %s overlap: %s" % (
                left_id, right_id, "; ".join(details)))
PY
}

verify_approved_manifest() {
  local CONTROL_PATH="$1"
  local MANIFEST_PATH="$2"
  shift 2
  python3 - "$CONTROL_PATH" "$MANIFEST_PATH" "$@" <<'PY'
import hashlib
import os
import re
import sys


def reject(message):
    sys.stderr.write("invalid approved hash manifest: %s\n" % message)
    raise SystemExit(1)


control = os.path.realpath(sys.argv[1])
manifest = sys.argv[2]
expected = sys.argv[3:]
line_pattern = re.compile(r"\A([0-9a-fA-F]{64})  ([A-Za-z0-9._-]+)\Z")

try:
    with open(manifest, "r") as handle:
        lines = handle.read().splitlines()
except IOError as exc:
    reject(str(exc))

if len(lines) != len(expected):
    reject("expected exactly %d entries" % len(expected))

seen = {}
for line in lines:
    match = line_pattern.match(line)
    if match is None:
        reject("entry is not an exact hash and basename pair")
    recorded_hash, basename = match.groups()
    if basename not in expected:
        reject("unexpected entry: %s" % basename)
    if basename in seen:
        reject("duplicate entry: %s" % basename)
    artifact = os.path.join(control, basename)
    if os.path.dirname(os.path.realpath(artifact)) != control:
        reject("entry escapes the control directory: %s" % basename)
    if os.path.islink(artifact) or not os.path.isfile(artifact):
        reject("artifact is missing or symlinked: %s" % basename)
    digest = hashlib.sha256()
    try:
        with open(artifact, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
    except IOError as exc:
        reject(str(exc))
    if digest.hexdigest() != recorded_hash.lower():
        reject("hash mismatch: %s" % basename)
    seen[basename] = True

if set(seen) != set(expected):
    reject("approved contract entries are incomplete")
PY
}

write_approved_manifest() {
  local VERIFIED_MANIFEST_PATH="$1"
  local STAGED_DAG_PATH="$2"
  local OUTPUT_PATH="$3"
  python3 - "$VERIFIED_MANIFEST_PATH" "$STAGED_DAG_PATH" "$OUTPUT_PATH" <<'PY'
import hashlib
import sys


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            result.update(chunk)
    return result.hexdigest()


verified_manifest, staged_dag, output = sys.argv[1:]
with open(verified_manifest, "rb") as handle:
    approved_entries = handle.read()
if approved_entries and not approved_entries.endswith(b"\n"):
    approved_entries += b"\n"
dag_entry = "%s  approved-task-dag.json\n" % digest(staged_dag)
with open(output, "wb") as handle:
    handle.write(approved_entries)
    handle.write(dag_entry.encode("ascii"))
PY
}

prepare_freeze_lock_file() {
  local REQUESTED_LOCK="$1"
  local LOCK_GUARD=""

  if [[ -d "$REQUESTED_LOCK" && ! -L "$REQUESTED_LOCK" ]]; then
    rmdir "$REQUESTED_LOCK" 2>/dev/null || {
      echo "unexpected task DAG freeze lock directory is not empty" >&2
      return 1
    }
  fi

  if [[ ! -e "$REQUESTED_LOCK" && ! -L "$REQUESTED_LOCK" ]]; then
    LOCK_GUARD="$(mktemp "$CONTROL_DIR/.task-dag-freeze.lockfile.XXXXXX")" || return 1
    chmod 0400 "$LOCK_GUARD" || return 1
    if ! ln "$LOCK_GUARD" "$REQUESTED_LOCK" 2>/dev/null; then
      [[ -e "$REQUESTED_LOCK" || -L "$REQUESTED_LOCK" ]] || return 1
    fi
    rm -f "$LOCK_GUARD"
  fi

  [[ -f "$REQUESTED_LOCK" && ! -L "$REQUESTED_LOCK" ]] || {
    echo "task DAG freeze lock must be a regular non-symlink file" >&2
    return 1
  }
}

acquire_freeze_lock() {
  local REQUESTED_LOCK="$1"
  local LOCK_RC=0
  prepare_freeze_lock_file "$REQUESTED_LOCK" || return 1
  exec 9< "$REQUESTED_LOCK" || return 1
  LOCK_FD_OPEN=1
  python3 - "$REQUESTED_LOCK" 9 <<'PY'
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
  LOCK_RC="$?"
  if [[ "$LOCK_RC" -ne 0 ]]; then
    exec 9>&-
    LOCK_FD_OPEN=0
    echo "task DAG freeze advisory lock is held or changed" >&2
    return 1
  fi
  LOCK_HELD=1
}

release_freeze_lock() {
  [[ "$LOCK_FD_OPEN" -eq 1 ]] || return 0
  exec 9>&- || return 1
  LOCK_FD_OPEN=0
  LOCK_HELD=0
}

verify_secured_partial_dag() {
  local SOURCE_PATH="$1"
  local DEST_PATH="$2"
  local GUARD_PATH="$3"
  [[ -f "$DEST_PATH" && ! -L "$DEST_PATH" && \
      -f "$GUARD_PATH" && ! -L "$GUARD_PATH" && \
      "$DEST_PATH" -ef "$GUARD_PATH" ]] || return 1
  cmp -s "$SOURCE_PATH" "$GUARD_PATH" || return 1
  validate_dag "$GUARD_PATH" || return 1
  python3 - "$GUARD_PATH" <<'PY'
import os
import stat
import sys


mode = stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)
raise SystemExit(0 if mode == 0o400 else 1)
PY
}

validate_task_registry_path() {
  local CONTROL_PATH="$1"
  python3 - "$CONTROL_PATH" <<'PY'
import errno
import os
import stat
import sys


control = sys.argv[1]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
control_fd = os.open(control, flags)
try:
    try:
        value = os.stat("tasks", dir_fd=control_fd, follow_symlinks=False)
    except OSError as error:
        if error.errno == errno.ENOENT:
            raise SystemExit(0)
        raise
    if not stat.S_ISDIR(value.st_mode):
        raise SystemExit(1)
finally:
    os.close(control_fd)
PY
}

ensure_task_registry() {
  local CONTROL_PATH="$1"
  python3 - "$CONTROL_PATH" <<'PY'
import errno
import os
import stat
import sys


control = sys.argv[1]
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
control_fd = os.open(control, flags)
created = False
try:
    try:
        os.mkdir("tasks", 0o700, dir_fd=control_fd)
        created = True
    except OSError as error:
        if error.errno != errno.EEXIST:
            raise
    value = os.stat("tasks", dir_fd=control_fd, follow_symlinks=False)
    if not stat.S_ISDIR(value.st_mode):
        raise SystemExit(1)
    tasks_fd = os.open("tasks", flags, dir_fd=control_fd)
    try:
        opened = os.fstat(tasks_fd)
        if ((opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino) or
                not stat.S_ISDIR(opened.st_mode)):
            raise SystemExit(1)
        os.fsync(tasks_fd)
    finally:
        os.close(tasks_fd)
    os.fsync(control_fd)
finally:
    os.close(control_fd)
print("created" if created else "existing")
PY
}

if [[ "$MODE" != "freeze" ]]; then
  validate_dag "$SOURCE_DAG"
  exit "$?"
fi

CONTROL_DIR="$2"
[[ -d "$CONTROL_DIR" && ! -L "$CONTROL_DIR" ]] || {
  echo "control directory is missing or symlinked: $CONTROL_DIR" >&2
  exit 1
}

for APPROVED in approved-design.md approved-plan.md brief-exec.md approved.sha256; do
  [[ -s "$CONTROL_DIR/$APPROVED" && ! -L "$CONTROL_DIR/$APPROVED" ]] || {
    echo "approved control artifact missing, empty, or symlinked: $CONTROL_DIR/$APPROVED" >&2
    exit 1
  }
done
validate_task_registry_path "$CONTROL_DIR" || {
  echo "coordinator task registry is an incompatible existing path" >&2
  exit 1
}

DEST="$CONTROL_DIR/approved-task-dag.json"
LOCK_DIR="$CONTROL_DIR/.task-dag-freeze.lock"
LOCK_HELD=0
LOCK_FD_OPEN=0
STAGED_DAG=""
STAGED_HASH=""
BACKUP_HASH=""
PARTIAL_DAG_GUARD=""
PARTIAL_GUARD_DIR=""
DAG_DEST_OWNED=0
TASK_REGISTRY_OWNED=0
HASH_PUBLICATION_ATTEMPTED=0
FREEZE_SUCCEEDED=0
cleanup() {
  local RC="$?"
  trap - EXIT HUP INT TERM
  if [[ "$FREEZE_SUCCEEDED" -ne 1 ]]; then
    if [[ "$HASH_PUBLICATION_ATTEMPTED" -eq 1 && -n "$BACKUP_HASH" && -e "$BACKUP_HASH" ]]; then
      mv -f "$BACKUP_HASH" "$CONTROL_DIR/approved.sha256" >/dev/null 2>&1 || true
      BACKUP_HASH=""
    fi
    if [[ "$DAG_DEST_OWNED" -eq 1 ]]; then
      if [[ -n "$STAGED_DAG" && -e "$STAGED_DAG" && \
            -e "$DEST" && "$DEST" -ef "$STAGED_DAG" ]]; then
        rm -f "$DEST"
      else
        echo "published DAG ownership changed; preserving destination" >&2
        RC=1
      fi
    fi
    if [[ "$TASK_REGISTRY_OWNED" -eq 1 ]]; then
      if ! rmdir "$CONTROL_DIR/tasks" 2>/dev/null; then
        echo "created task registry changed; preserving it" >&2
        RC=1
      fi
    fi
  fi
  [[ -z "$STAGED_DAG" ]] || rm -f "$STAGED_DAG"
  [[ -z "$STAGED_HASH" ]] || rm -f "$STAGED_HASH"
  [[ -z "$BACKUP_HASH" ]] || rm -f "$BACKUP_HASH"
  [[ -z "$PARTIAL_DAG_GUARD" ]] || rm -f "$PARTIAL_DAG_GUARD"
  [[ -z "$PARTIAL_GUARD_DIR" ]] || rmdir "$PARTIAL_GUARD_DIR" 2>/dev/null || true
  if ! release_freeze_lock; then
    echo "task DAG freeze lock could not be released safely" >&2
    RC=1
  fi
  exit "$RC"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

umask 077
acquire_freeze_lock "$LOCK_DIR" || exit 1
STAGED_DAG="$(mktemp "$CONTROL_DIR/.approved-task-dag.json.XXXXXX")" || exit 1
cp "$SOURCE_DAG" "$STAGED_DAG" || exit 1
chmod 0400 "$STAGED_DAG" || exit 1
validate_dag "$STAGED_DAG" || exit 1

BACKUP_HASH="$(mktemp "$CONTROL_DIR/.approved.sha256.backup.XXXXXX")" || exit 1
cp "$CONTROL_DIR/approved.sha256" "$BACKUP_HASH" || exit 1
chmod 0400 "$BACKUP_HASH" || exit 1

FREEZE_STATE=""
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ -s "$DEST" && ! -L "$DEST" ]] || {
    echo "existing approved task DAG is empty or symlinked" >&2
    exit 1
  }
  validate_dag "$DEST" || {
    echo "existing approved task DAG is invalid" >&2
    exit 1
  }
  if verify_approved_manifest "$CONTROL_DIR" "$BACKUP_HASH" \
      approved-design.md approved-plan.md brief-exec.md approved-task-dag.json \
      >/dev/null 2>&1; then
    cmp -s "$STAGED_DAG" "$DEST" || {
      echo "approved task DAG conflicts with the requested source" >&2
      exit 1
    }
    FREEZE_STATE="complete"
  elif verify_approved_manifest "$CONTROL_DIR" "$BACKUP_HASH" \
      approved-design.md approved-plan.md brief-exec.md >/dev/null 2>&1; then
    cmp -s "$STAGED_DAG" "$DEST" || {
      echo "partial approved task DAG conflicts with the requested source" >&2
      exit 1
    }
    FREEZE_STATE="partial"
  else
    echo "existing approved task DAG has no trusted matching hash state" >&2
    exit 1
  fi
else
  verify_approved_manifest "$CONTROL_DIR" "$BACKUP_HASH" \
    approved-design.md approved-plan.md brief-exec.md || exit 1
  FREEZE_STATE="empty"
fi

if [[ "$FREEZE_STATE" == "complete" ]]; then
  TASK_REGISTRY_RESULT="$(ensure_task_registry "$CONTROL_DIR")" || {
    echo "coordinator task registry could not be initialized safely" >&2
    exit 1
  }
  [[ "$TASK_REGISTRY_RESULT" != created ]] || TASK_REGISTRY_OWNED=1
  FREEZE_SUCCEEDED=1
  rm -f "$BACKUP_HASH"
  BACKUP_HASH=""
  exit 0
fi

if [[ "$FREEZE_STATE" == "partial" ]]; then
  PARTIAL_GUARD_DIR="$(mktemp -d "$CONTROL_DIR/.approved-task-dag.recovery.XXXXXX")" || exit 1
  PARTIAL_DAG_GUARD="$PARTIAL_GUARD_DIR/dag"
  ln "$DEST" "$PARTIAL_DAG_GUARD" || exit 1
  [[ "$DEST" -ef "$PARTIAL_DAG_GUARD" ]] || exit 1
  chmod 0400 "$PARTIAL_DAG_GUARD" || exit 1
  verify_secured_partial_dag "$STAGED_DAG" "$DEST" "$PARTIAL_DAG_GUARD" || {
    echo "partial approved task DAG could not be secured" >&2
    exit 1
  }
fi

STAGED_HASH="$(mktemp "$CONTROL_DIR/.approved.sha256.XXXXXX")" || exit 1
write_approved_manifest "$BACKUP_HASH" "$STAGED_DAG" "$STAGED_HASH" || exit 1
chmod 0400 "$STAGED_HASH" || exit 1

if [[ "$FREEZE_STATE" == "empty" ]]; then
  if ! ln "$STAGED_DAG" "$DEST"; then
    echo "approved task DAG destination appeared during publication" >&2
    exit 1
  fi
  [[ "$DEST" -ef "$STAGED_DAG" ]] || {
    echo "approved task DAG publication ownership mismatch" >&2
    exit 1
  }
  DAG_DEST_OWNED=1
fi
if [[ "$FREEZE_STATE" == "partial" ]]; then
  verify_secured_partial_dag "$STAGED_DAG" "$DEST" "$PARTIAL_DAG_GUARD" || {
    echo "partial approved task DAG changed before authority publication" >&2
    exit 1
  }
fi

TASK_REGISTRY_RESULT="$(ensure_task_registry "$CONTROL_DIR")" || {
  echo "coordinator task registry could not be initialized safely" >&2
  exit 1
}
[[ "$TASK_REGISTRY_RESULT" != created ]] || TASK_REGISTRY_OWNED=1
HASH_PUBLICATION_ATTEMPTED=1
mv "$STAGED_HASH" "$CONTROL_DIR/approved.sha256" || exit 1
STAGED_HASH=""
if [[ "$DAG_DEST_OWNED" -eq 1 ]]; then
  [[ "$DEST" -ef "$STAGED_DAG" ]] || {
    echo "approved task DAG ownership changed before finalization" >&2
    exit 1
  }
  chmod 0444 "$DEST" || exit 1
fi
chmod 0444 "$CONTROL_DIR/approved.sha256" || exit 1

verify_approved_manifest "$CONTROL_DIR" "$CONTROL_DIR/approved.sha256" \
  approved-design.md approved-plan.md brief-exec.md approved-task-dag.json || {
  echo "frozen approved contract hash verification failed" >&2
  exit 1
}
if [[ "$FREEZE_STATE" == "partial" ]]; then
  verify_secured_partial_dag "$STAGED_DAG" "$DEST" "$PARTIAL_DAG_GUARD" || {
    echo "partial approved task DAG changed during final verification" >&2
    exit 1
  }
fi

FREEZE_SUCCEEDED=1
rm -f "$BACKUP_HASH"
BACKUP_HASH=""
