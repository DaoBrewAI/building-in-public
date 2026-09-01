#!/usr/bin/env bash
# Commit broker for Codex implementation turns (P0-1 of the 2026-08-08 retrospective).
#
# The codex workspace-write sandbox keeps the ACTIVE git database semantically
# read-only (verified on codex-cli 0.147.0: renamed gitdirs, standalone
# conversion, and extra writable roots all fail) — the executor can never
# commit. The coordinator imports the accepted native task outcome and writes
#   $MISSION_DIR/COMMIT-REQUEST-<n>.json
#     {"protocol_version":1,"task_id":"<task>","generation":1,
#      "accepted_thread_id":"<thread>","outcome_nonce":"<nonce>",
#      "outcome_digest":"<bound outcome event sha256>",
#      "base_sha":"<registered-base>","diff_sha256":"<canonical-diff>",
#      "worktree":"<abs>","paths":["rel"...],"message":"..."}
# The broker publishes an identity-bound response, which the coordinator sends
# back to the same accepted child for post-commit verification:
#   $MISSION_DIR/COMMIT-DONE-<n>.json      {identity..., "hash":"...", "branch":"..."}
#   $MISSION_DIR/COMMIT-REJECTED-<n>.json  {identity..., "reason":"..."}
#
# The coordinator runs this loop alongside the app-native child task
# and stops it when the implementation turn ends. --once processes the backlog.
#
#   commit-broker.sh --mission-dir <dir> --control-dir <dir> [--once] [--interval <seconds>]
#
# Validation per request (any failure -> REJECTED, never a partial commit):
#   - request identity matches coordinator-owned generation/thread/nonce/base
#   - worker-facing worktrees.txt still matches the coordinator-owned copy
#   - worktree is one registered in $CONTROL_DIR/worktrees.txt
#   - paths are relative, contain no "..", and resolve inside the worktree
#   - no path is a shared or local Claude settings file
#   - requested and actual dirty paths stay within the task's frozen DAG files
#   - diff_sha256 matches the canonical current bytes for sorted requested paths
#   - the worktree has no modifications OUTSIDE the requested paths
#     (untracked-but-ignored files aside) — ask the executor to split requests

set -uo pipefail

MISSION_DIR="" CONTROL_DIR="" ONCE=0 INTERVAL=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --control-dir) CONTROL_DIR="$2"; shift 2 ;;
    --once)        ONCE=1; shift ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$MISSION_DIR" || ! -d "$MISSION_DIR" || -L "$MISSION_DIR" || -z "$CONTROL_DIR" || ! -d "$CONTROL_DIR" || -L "$CONTROL_DIR" ]]; then
  echo "usage: commit-broker.sh --mission-dir <dir> --control-dir <dir> [--once] [--interval <s>]" >&2
  exit 1
fi
MANIFEST="$CONTROL_DIR/worktrees.txt"
WORKER_MANIFEST="$MISSION_DIR/worktrees.txt"
if [[ ! -s "$MANIFEST" || -L "$MANIFEST" ]]; then
  echo "coordinator control manifest missing, empty, or symlinked: $MANIFEST" >&2
  exit 1
fi
CONTROL_TASK_ID="$(basename "$CONTROL_DIR")"
CONTROL_ROOT="$(cd "$CONTROL_DIR/../.." 2>/dev/null && pwd -P)" || {
  echo "could not resolve coordinator control root from task control: $CONTROL_DIR" >&2
  exit 1
}
APPROVED_DAG="$CONTROL_ROOT/approved-task-dag.json"
APPROVAL_HELPER="$(cd "$(dirname "$0")" && pwd -P)/verify-approved-authority.py"
LIFECYCLE_HELPER="$(cd "$(dirname "$0")" && pwd -P)/coordinator_lifecycle_lock.py"
BROKER_LOCK_FILE="$CONTROL_DIR/.commit-broker.lock"

acquire_broker_lock() {
  local CANDIDATE
  if [[ ! -e "$BROKER_LOCK_FILE" && ! -L "$BROKER_LOCK_FILE" ]]; then
    CANDIDATE="$(mktemp "$CONTROL_DIR/.commit-broker.lockfile.XXXXXX")" || return 1
    chmod 0600 "$CANDIDATE" || { rm -f -- "$CANDIDATE"; return 1; }
    if ! ln "$CANDIDATE" "$BROKER_LOCK_FILE" 2>/dev/null; then
      [[ -e "$BROKER_LOCK_FILE" || -L "$BROKER_LOCK_FILE" ]] || {
        rm -f -- "$CANDIDATE"
        return 1
      }
    fi
    rm -f -- "$CANDIDATE"
  fi
  [[ -f "$BROKER_LOCK_FILE" && ! -L "$BROKER_LOCK_FILE" ]] || return 1
  exec 9< "$BROKER_LOCK_FILE" || return 1
  python3 - "$BROKER_LOCK_FILE" 9 <<'PY'
import fcntl
import os
import stat
import sys

path = sys.argv[1]
descriptor = int(sys.argv[2])
opened = os.fstat(descriptor)
current = os.lstat(path)
if (not stat.S_ISREG(opened.st_mode) or stat.S_ISLNK(current.st_mode) or
        (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
    raise SystemExit(1)
fcntl.flock(descriptor, fcntl.LOCK_EX)
current = os.lstat(path)
if (stat.S_ISLNK(current.st_mode) or
        (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
    raise SystemExit(1)
PY
}

release_broker_lock() {
  exec 9>&-
}

acquire_shared_lifecycle_lock() {
  [[ -x "$LIFECYCLE_HELPER" ]] || return 1
  LIFECYCLE_LOCK_FILE="$(python3 "$LIFECYCLE_HELPER" prepare --control-dir "$CONTROL_ROOT")" || return 1
  exec 8< "$LIFECYCLE_LOCK_FILE" || return 1
  if ! python3 "$LIFECYCLE_HELPER" acquire-fd \
      --lock-file "$LIFECYCLE_LOCK_FILE" --fd 8; then
    exec 8>&-
    return 1
  fi
}

release_shared_lifecycle_lock() {
  exec 8>&-
}

read_control_scalar() { # <path> <label>
  local PATHNAME="$1" LABEL="$2" VALUE
  if [[ ! -f "$PATHNAME" || -L "$PATHNAME" ]]; then
    echo "coordinator $LABEL missing or symlinked: $PATHNAME" >&2
    return 1
  fi
  VALUE="$(python3 - "$PATHNAME" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
if not data.endswith(b"\n") or data.count(b"\n") != 1 or b"\r" in data or b"\0" in data:
    raise SystemExit(1)
try:
    value = data[:-1].decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)
if not value:
    raise SystemExit(1)
print(value)
PY
)" || {
    echo "coordinator $LABEL is not strict one-line UTF-8 authority: $PATHNAME" >&2
    return 1
  }
  printf '%s' "$VALUE"
}

refresh_control_authority() {
  local GENERATION ACCEPTED_THREAD_ID OUTCOME_NONCE
  GENERATION="$(read_control_scalar "$CONTROL_DIR/generation" "generation")" || return 1
  ACCEPTED_THREAD_ID="$(read_control_scalar "$CONTROL_DIR/accepted-thread-id" "accepted thread")" || return 1
  OUTCOME_NONCE="$(read_control_scalar "$CONTROL_DIR/outcome-nonce" "outcome nonce")" || return 1
  case "$GENERATION" in ''|*[!0-9]*|0) echo "coordinator generation is invalid" >&2; return 1 ;; esac
  CONTROL_GENERATION="$GENERATION"
  CONTROL_ACCEPTED_THREAD_ID="$ACCEPTED_THREAD_ID"
  CONTROL_OUTCOME_NONCE="$OUTCOME_NONCE"
}

refresh_control_authority || exit 1
CONTROL_TASK_STATE_DIR="$(read_control_scalar "$CONTROL_DIR/task-state-dir" "task state directory")" || exit 1
case "$CONTROL_TASK_STATE_DIR" in /*) ;; *) echo "coordinator task state directory is not absolute" >&2; exit 1 ;; esac
if [[ ! -d "$CONTROL_TASK_STATE_DIR" || -L "$CONTROL_TASK_STATE_DIR" || \
      "$(cd "$CONTROL_TASK_STATE_DIR" && pwd -P)" != "$(cd "$MISSION_DIR" && pwd -P)" ]]; then
  echo "mission-dir does not match coordinator task-state-dir authority" >&2
  exit 1
fi
if [[ ! -x "$APPROVAL_HELPER" ]]; then
  echo "frozen approval verifier is unavailable" >&2
  exit 1
fi
ALLOWED_PATHS_JSON="$("$APPROVAL_HELPER" --control-dir "$CONTROL_ROOT" --task-files "$CONTROL_TASK_ID" 2>/dev/null)" || {
  echo "frozen approval authority does not contain one valid task node for $CONTROL_TASK_ID" >&2
  exit 1
}
REQUEST_SHA256=""
RESPONSE_TASK_ID="$CONTROL_TASK_ID"
RESPONSE_GENERATION="$CONTROL_GENERATION"
RESPONSE_ACCEPTED_THREAD_ID="$CONTROL_ACCEPTED_THREAD_ID"
RESPONSE_OUTCOME_NONCE="$CONTROL_OUTCOME_NONCE"

request_sha256() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

set_response_identity() { # <valid-json-request>
  local VALUE
  if jq -e '.task_id | type == "string" and length > 0' "$1" >/dev/null 2>&1; then
    RESPONSE_TASK_ID="$(jq -r '.task_id' "$1")"
  fi
  if jq -e '.generation | type == "number" and . == floor and . > 0' "$1" >/dev/null 2>&1; then
    VALUE="$(jq -r '.generation' "$1")"
    case "$VALUE" in ''|*[!0-9]*) ;; *) RESPONSE_GENERATION="$VALUE" ;; esac
  fi
  if jq -e '.accepted_thread_id | type == "string" and length > 0' "$1" >/dev/null 2>&1; then
    RESPONSE_ACCEPTED_THREAD_ID="$(jq -r '.accepted_thread_id' "$1")"
  fi
  if jq -e '.outcome_nonce | type == "string" and length > 0' "$1" >/dev/null 2>&1; then
    RESPONSE_OUTCOME_NONCE="$(jq -r '.outcome_nonce' "$1")"
  fi
}

write_response() { # <DONE|REJECTED> <n> <payload jq args...>
  local KIND="$1" N="$2" DESTINATION TEMPORARY
  shift 2
  DESTINATION="$MISSION_DIR/COMMIT-$KIND-$N.json"
  TEMPORARY="$(mktemp "$MISSION_DIR/.COMMIT-$KIND-$N.json.XXXXXX")" || return 1
  if ! jq -n \
      --argjson protocol_version 1 \
      --arg task_id "$RESPONSE_TASK_ID" \
      --argjson generation "$RESPONSE_GENERATION" \
      --arg accepted_thread_id "$RESPONSE_ACCEPTED_THREAD_ID" \
      --arg outcome_nonce "$RESPONSE_OUTCOME_NONCE" \
      --arg request_sha256 "$REQUEST_SHA256" \
      "$@" > "$TEMPORARY"; then
    rm -f "$TEMPORARY"
    return 1
  fi
  if ! ln "$TEMPORARY" "$DESTINATION" 2>/dev/null; then
    rm -f -- "$TEMPORARY"
    return 1
  fi
  if [[ ! "$TEMPORARY" -ef "$DESTINATION" ]]; then
    rm -f -- "$TEMPORARY"
    return 1
  fi
  rm -f -- "$TEMPORARY"
}

reject() { # <n> <reason>
  local N="$1" REASON="$2"
  write_response REJECTED "$N" --arg reason "$REASON" \
    '{protocol_version:$protocol_version,task_id:$task_id,generation:$generation,
      accepted_thread_id:$accepted_thread_id,outcome_nonce:$outcome_nonce,
      request_sha256:$request_sha256,reason:$reason}' || return 1
  echo "$(date -u +%FT%TZ) REJECTED $N: $REASON"
}

durable_sync() { # <regular-file-or-directory>...
  python3 - "$@" <<'PY'
import os
import stat
import sys

for path in sys.argv[1:]:
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode) or not (
        stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)
    ):
        raise SystemExit(1)
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

publish_commit_intent() { # <path> <parent> <tree> <commit> <branch> <paths-json> <diff>
  local DESTINATION="$1" PARENT="$2" TREE="$3" COMMIT="$4" BRANCH_NAME="$5"
  local PATHS_JSON="$6" DIFF="$7" TEMPORARY
  TEMPORARY="$(mktemp "$MISSION_DIR/.COMMIT-INTENT.XXXXXX")" || return 1
  if ! jq -Scn \
      --argjson protocol_version 1 \
      --arg request_sha256 "$REQUEST_SHA256" \
      --arg task_id "$REQUEST_TASK_ID" \
      --argjson generation "$REQUEST_GENERATION" \
      --arg accepted_thread_id "$REQUEST_ACCEPTED_THREAD_ID" \
      --arg outcome_nonce "$REQUEST_OUTCOME_NONCE" \
      --arg parent_sha "$PARENT" \
      --arg tree_sha "$TREE" \
      --arg commit_sha "$COMMIT" \
      --arg branch "$BRANCH_NAME" \
      --argjson paths "$PATHS_JSON" \
      --arg diff_sha256 "$DIFF" \
      '{protocol_version:$protocol_version,request_sha256:$request_sha256,
        task_id:$task_id,generation:$generation,
        accepted_thread_id:$accepted_thread_id,outcome_nonce:$outcome_nonce,
        parent_sha:$parent_sha,tree_sha:$tree_sha,commit_sha:$commit_sha,
        branch:$branch,paths:$paths,diff_sha256:$diff_sha256}' > "$TEMPORARY"; then
    rm -f -- "$TEMPORARY"
    return 1
  fi
  durable_sync "$TEMPORARY" || { rm -f -- "$TEMPORARY"; return 1; }
  if ln "$TEMPORARY" "$DESTINATION" 2>/dev/null; then
    [[ "$TEMPORARY" -ef "$DESTINATION" ]] || { rm -f -- "$TEMPORARY"; return 1; }
    durable_sync "$DESTINATION" "$MISSION_DIR" || { rm -f -- "$TEMPORARY"; return 1; }
  else
    [[ -f "$DESTINATION" && ! -L "$DESTINATION" ]] || { rm -f -- "$TEMPORARY"; return 1; }
    cmp -s "$TEMPORARY" "$DESTINATION" || { rm -f -- "$TEMPORARY"; return 1; }
  fi
  rm -f -- "$TEMPORARY"
}

validate_commit_intent_schema() { # <intent>
  jq -e '
    type == "object" and
    keys == ["accepted_thread_id","branch","commit_sha","diff_sha256",
             "generation","outcome_nonce","parent_sha","paths",
             "protocol_version","request_sha256","task_id","tree_sha"] and
    .protocol_version == 1 and
    (.request_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.task_id | type == "string" and length > 0) and
    (.generation | type == "number" and . == floor and . > 0) and
    (.accepted_thread_id | type == "string" and length > 0) and
    (.outcome_nonce | type == "string" and length > 0) and
    (.parent_sha | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
    (.tree_sha | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
    (.commit_sha | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
    (.branch | type == "string" and length > 0) and
    (.paths | type == "array" and length > 0 and
      all(.[]; type == "string" and length > 0)) and
    (.diff_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$1" >/dev/null 2>&1
}

json_array_contains() { # <json-array> <value>
  jq -e --arg value "$2" 'index($value) != null' <<< "$1" >/dev/null 2>&1
}

compute_diff_sha256() { # <worktree> <paths-json>
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
import stat
from pathlib import Path
import sys

root = Path(sys.argv[1])
paths = sorted(json.loads(sys.argv[2]))
payload = bytearray()
for relative in paths:
    target = root / relative
    if target.is_file() and not target.is_symlink():
        state = b"file"
        mode = b"100755" if os.lstat(target).st_mode & 0o111 else b"100644"
        digest = hashlib.sha256(target.read_bytes()).hexdigest().encode("ascii")
    elif not os.path.lexists(target):
        state = b"deleted"
        mode = b"000000"
        digest = b""
    else:
        raise SystemExit(1)
    payload.extend(relative.encode("utf-8"))
    payload.extend(b"\0" + state + b"\0" + mode + b"\0" + digest + b"\n")
print(hashlib.sha256(payload).hexdigest())
PY
}

staged_paths_json() { # <worktree>
  python3 - "$1" <<'PY'
import json
import subprocess
import sys

completed = subprocess.run(
    ["git", "-C", sys.argv[1], "diff", "--cached", "--name-only", "--no-renames", "-z", "--"],
    check=True,
    stdout=subprocess.PIPE,
)
raw_paths = completed.stdout.split(b"\0")
if raw_paths and raw_paths[-1] == b"":
    raw_paths.pop()
try:
    paths = [path.decode("utf-8") for path in raw_paths]
except UnicodeDecodeError:
    raise SystemExit(1)
print(json.dumps(sorted(paths), separators=(",", ":"), ensure_ascii=False))
PY
}

compute_index_diff_sha256() { # <worktree> <paths-json>
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import subprocess
import sys

root = sys.argv[1]
paths = sorted(json.loads(sys.argv[2]))
payload = bytearray()
for relative in paths:
    staged = subprocess.run(
        ["git", "-C", root, "ls-files", "--stage", "-z", "--", relative],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    records = [record for record in staged.split(b"\0") if record]
    if not records:
        state = b"deleted"
        mode = b"000000"
        digest = b""
    else:
        if len(records) != 1:
            raise SystemExit(1)
        metadata, staged_path = records[0].split(b"\t", 1)
        mode, object_id, stage = metadata.split(b" ")
        if stage != b"0" or mode not in {b"100644", b"100755"}:
            raise SystemExit(1)
        if staged_path.decode("utf-8") != relative:
            raise SystemExit(1)
        content = subprocess.run(
            ["git", "-C", root, "cat-file", "blob", object_id.decode("ascii")],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        state = b"file"
        digest = hashlib.sha256(content).hexdigest().encode("ascii")
    payload.extend(relative.encode("utf-8"))
    payload.extend(b"\0" + state + b"\0" + mode + b"\0" + digest + b"\n")
print(hashlib.sha256(payload).hexdigest())
PY
}

tree_paths_json() { # <worktree> <parent> <treeish>
  python3 - "$1" "$2" "$3" <<'PY'
import json
import subprocess
import sys

completed = subprocess.run(
    ["git", "-C", sys.argv[1], "diff-tree", "--no-commit-id", "--name-only",
     "--no-renames", "-r", "-z", sys.argv[2], sys.argv[3], "--"],
    check=True,
    stdout=subprocess.PIPE,
)
raw_paths = completed.stdout.split(b"\0")
if raw_paths and raw_paths[-1] == b"":
    raw_paths.pop()
try:
    paths = [path.decode("utf-8") for path in raw_paths]
except UnicodeDecodeError:
    raise SystemExit(1)
print(json.dumps(sorted(paths), separators=(",", ":"), ensure_ascii=False))
PY
}

compute_tree_diff_sha256() { # <worktree> <treeish> <paths-json>
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import subprocess
import sys

root, treeish = sys.argv[1:3]
paths = sorted(json.loads(sys.argv[3]))
payload = bytearray()
for relative in paths:
    listed = subprocess.run(
        ["git", "-C", root, "ls-tree", "-z", treeish, "--", relative],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    records = [record for record in listed.split(b"\0") if record]
    if not records:
        state = b"deleted"
        mode = b"000000"
        digest = b""
    else:
        if len(records) != 1:
            raise SystemExit(1)
        metadata, tree_path = records[0].split(b"\t", 1)
        mode, object_type, object_id = metadata.split(b" ")
        if mode not in {b"100644", b"100755"} or object_type != b"blob":
            raise SystemExit(1)
        if tree_path.decode("utf-8") != relative:
            raise SystemExit(1)
        content = subprocess.run(
            ["git", "-C", root, "cat-file", "blob", object_id.decode("ascii")],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        state = b"file"
        digest = hashlib.sha256(content).hexdigest().encode("ascii")
    payload.extend(relative.encode("utf-8"))
    payload.extend(b"\0" + state + b"\0" + mode + b"\0" + digest + b"\n")
print(hashlib.sha256(payload).hexdigest())
PY
}

broker_test_hook() { # <hook-name>; inert unless the focused test enables it
  local NAME="$1" HOOK_DIR="${ORC_COMMIT_BROKER_TEST_HOOK_DIR:-}"
  local ENABLED_NAME="${ORC_COMMIT_BROKER_TEST_HOOK_NAME:-}" ATTEMPT=0
  [[ -n "$HOOK_DIR" ]] || return 0
  [[ "$NAME" == "$ENABLED_NAME" ]] || return 0
  if [[ ! -d "$HOOK_DIR" || -L "$HOOK_DIR" ]]; then
    return 1
  fi
  printf '%s\n' "$$" > "$HOOK_DIR/reached-$NAME" || return 1
  while [[ ! -e "$HOOK_DIR/continue-$NAME" ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    [[ "$ATTEMPT" -lt 500 ]] || return 1
    sleep 0.01
  done
}

dirty_paths() { # <worktree>; emits NUL-delimited paths, duplicates harmless
  git -C "$1" diff --name-only --no-renames -z -- 2>/dev/null
  git -C "$1" diff --cached --name-only --no-renames -z -- 2>/dev/null
  git -C "$1" ls-files --others --exclude-standard -z 2>/dev/null
}

process_request_transaction() { # <request file>
  local REQ="$1" N WT MSG REGISTERED_WT REGISTERED_BRANCH REGISTERED_BASE
  local REQUEST_PATHS_JSON REQUEST_TASK_ID REQUEST_GENERATION
  local REQUEST_ACCEPTED_THREAD_ID REQUEST_OUTCOME_NONCE REQUEST_BASE_SHA REQUEST_DIFF_SHA256
  local REQUEST_OUTCOME_DIGEST CONTROL_OUTCOME_DIGEST CONTROL_TASK_STATE WORKER_TASK_STATE
  local P DIRTY_PATH SCOPE_EXTRA="" REQUEST_EXTRA="" ACTUAL_DIFF INDEX_DIFF
  local STAGED_PATHS_JSON REQUEST_PATHS_SORTED_JSON
  local OUT HASH BRANCH CURRENT_BRANCH MANIFEST_PHYS PARENT_HASH TREE_SHA
  local TREE_PATHS_JSON TREE_DIFF COMMITTED_TREE COMMITTED_PATHS_JSON COMMITTED_DIFF
  local INTENT INTENT_PARENT="" INTENT_TREE="" INTENT_HASH="" INTENT_BRANCH=""
  local INTENT_PATHS_JSON="" INTENT_DIFF="" INTENT_TIP="" INTENT_MESSAGE=""
  local INTENT_COMMIT_OBJECT="" INTENT_COMMIT_PARENT="" INTENT_COMMIT_EXTRA=""
  N="${REQ##*COMMIT-REQUEST-}"; N="${N%.json}"
  # Already answered -> skip (executor may retry with a new n after REJECTED).
  if [[ -e "$MISSION_DIR/COMMIT-DONE-$N.json" || -L "$MISSION_DIR/COMMIT-DONE-$N.json" ||
        -e "$MISSION_DIR/COMMIT-REJECTED-$N.json" || -L "$MISSION_DIR/COMMIT-REJECTED-$N.json" ]]; then
    return 0
  fi

  REQUEST_SHA256="$(request_sha256 "$REQ")"
  refresh_control_authority || return 1
  RESPONSE_TASK_ID="$CONTROL_TASK_ID"
  RESPONSE_GENERATION="$CONTROL_GENERATION"
  RESPONSE_ACCEPTED_THREAD_ID="$CONTROL_ACCEPTED_THREAD_ID"
  RESPONSE_OUTCOME_NONCE="$CONTROL_OUTCOME_NONCE"

  if ! jq -e . "$REQ" >/dev/null 2>&1; then
    # Possibly caught mid-write; leave it alone until it is a few seconds old.
    local AGE
    AGE="$(( $(date +%s) - $(stat -f %m "$REQ" 2>/dev/null || echo 0) ))"
    if [[ "$AGE" -lt 5 ]]; then return 0; fi
    reject "$N" "COMMIT-REQUEST-$N.json is not valid JSON"
    return 0
  fi
  set_response_identity "$REQ"

  if ! cmp -s "$MANIFEST" "$WORKER_MANIFEST"; then
    reject "$N" "worker manifest does not match coordinator control manifest"
    return 0
  fi

  if ! jq -e '
      type == "object" and
      keys == ["accepted_thread_id","base_sha","diff_sha256","generation","message",
               "outcome_digest","outcome_nonce","paths","protocol_version","task_id","worktree"]
    ' "$REQ" >/dev/null 2>&1; then
    reject "$N" "request must carry exactly the protocol v1 fields"
    return 0
  fi
  if ! jq -e '.protocol_version == 1' "$REQ" >/dev/null 2>&1; then
    reject "$N" "unsupported or missing protocol_version"
    return 0
  fi
  if ! jq -e '
      (.task_id | type == "string" and length > 0 and
        (contains("\u0000") or contains("\r") or contains("\n") | not)) and
      (.generation | type == "number" and . == floor and . > 0) and
      (.accepted_thread_id | type == "string" and length > 0 and
        (contains("\u0000") or contains("\r") or contains("\n") | not)) and
      (.outcome_nonce | type == "string" and length > 0 and
        (contains("\u0000") or contains("\r") or contains("\n") | not)) and
      (.outcome_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.base_sha | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
      (.diff_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.worktree | type == "string" and length > 0 and (contains("\u0000") | not)) and
      (.message | type == "string" and length > 0 and (contains("\u0000") | not)) and
      (.paths | type == "array" and length > 0 and
        all(.[]; type == "string" and length > 0 and
          (contains("\u0000") or contains("\r") or contains("\n") | not))) and
      ((.paths | length) == (.paths | unique | length))
    ' "$REQ" >/dev/null 2>&1; then
    reject "$N" "request protocol fields have invalid types or values"
    return 0
  fi

  REQUEST_TASK_ID="$(jq -r '.task_id' "$REQ")"
  REQUEST_GENERATION="$(jq -r '.generation' "$REQ")"
  REQUEST_ACCEPTED_THREAD_ID="$(jq -r '.accepted_thread_id' "$REQ")"
  REQUEST_OUTCOME_NONCE="$(jq -r '.outcome_nonce' "$REQ")"
  REQUEST_OUTCOME_DIGEST="$(jq -r '.outcome_digest' "$REQ")"
  REQUEST_BASE_SHA="$(jq -r '.base_sha' "$REQ")"
  REQUEST_DIFF_SHA256="$(jq -r '.diff_sha256' "$REQ")"
  WT="$(jq -r '.worktree // empty' "$REQ")"
  MSG="$(jq -r '.message // empty' "$REQ")"
  REQUEST_PATHS_JSON="$(jq -c '.paths' "$REQ")"
  REQUEST_PATHS_SORTED_JSON="$(jq -c 'sort' <<< "$REQUEST_PATHS_JSON")"

  if [[ "$REQUEST_TASK_ID" != "$CONTROL_TASK_ID" ]]; then
    reject "$N" "task_id does not match coordinator task control"
    return 0
  fi
  if [[ "$REQUEST_GENERATION" != "$CONTROL_GENERATION" ]]; then
    reject "$N" "generation does not match coordinator authority"
    return 0
  fi
  if [[ "$REQUEST_ACCEPTED_THREAD_ID" != "$CONTROL_ACCEPTED_THREAD_ID" ]]; then
    reject "$N" "accepted_thread_id does not match coordinator authority"
    return 0
  fi
  if [[ "$REQUEST_OUTCOME_NONCE" != "$CONTROL_OUTCOME_NONCE" ]]; then
    reject "$N" "outcome_nonce does not match coordinator authority"
    return 0
  fi

  # A request may become visible before task-outcome finishes its durable
  # transaction. Never let the resident broker consume it until the exact
  # outcome intent is cleared and both state copies plus latest pointer agree.
  if [[ -e "$CONTROL_DIR/.outcome-intent.json" || -L "$CONTROL_DIR/.outcome-intent.json" ]]; then
    return 0
  fi
  CONTROL_TASK_STATE="$(read_control_scalar "$CONTROL_DIR/state" "task state")" || return 1
  WORKER_TASK_STATE="$(read_control_scalar "$MISSION_DIR/state" "worker task state")" || return 1
  CONTROL_OUTCOME_DIGEST="$(read_control_scalar "$CONTROL_DIR/latest-outcome" "latest outcome")" || return 1
  if [[ "$CONTROL_TASK_STATE" != ready_for_commit || "$WORKER_TASK_STATE" != ready_for_commit || \
        "$CONTROL_OUTCOME_DIGEST" != "$REQUEST_OUTCOME_DIGEST" ]]; then
    return 0
  fi

  case "$WT" in
    /*) ;;
    *) reject "$N" "worktree must be an absolute registered path: $WT"; return 0 ;;
  esac
  if [[ ! -d "$WT" ]]; then
    reject "$N" "worktree does not exist: $WT"
    return 0
  fi
  WT="$(cd "$WT" && pwd -P)"
  REGISTERED_WT=""
  REGISTERED_BRANCH=""
  REGISTERED_BASE=""
  while IFS=$'\t' read -r MANIFEST_WT MANIFEST_BRANCH MANIFEST_BASE MANIFEST_REPO EXTRA || [[ -n "${MANIFEST_WT:-}" ]]; do
    [[ -n "$MANIFEST_WT" && -n "$MANIFEST_BRANCH" && -n "$MANIFEST_BASE" && -n "$MANIFEST_REPO" && -z "${EXTRA:-}" ]] || continue
    [[ -d "$MANIFEST_WT" ]] || continue
    MANIFEST_PHYS="$(cd "$MANIFEST_WT" && pwd -P)"
    if [[ "$WT" == "$MANIFEST_PHYS" ]]; then
      REGISTERED_WT="$MANIFEST_PHYS"
      REGISTERED_BRANCH="$MANIFEST_BRANCH"
      REGISTERED_BASE="$MANIFEST_BASE"
      break
    fi
  done < "$MANIFEST"
  if [[ -z "$REGISTERED_WT" ]]; then
    reject "$N" "worktree not registered in coordinator control manifest: $WT"
    return 0
  fi
  if [[ "$REQUEST_BASE_SHA" != "$REGISTERED_BASE" ]]; then
    reject "$N" "base_sha does not match registered task manifest base"
    return 0
  fi
  if [[ "$(git -C "$WT" rev-parse --verify "${REGISTERED_BASE}^{commit}" 2>/dev/null || true)" != "$REGISTERED_BASE" ]] ||
      ! git -C "$WT" merge-base --is-ancestor "$REGISTERED_BASE" HEAD >/dev/null 2>&1; then
    reject "$N" "registered task manifest base is not valid ancestry for the worktree"
    return 0
  fi
  CURRENT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$CURRENT_BRANCH" != "$REGISTERED_BRANCH" ]]; then
    reject "$N" "worktree branch mismatch: expected $REGISTERED_BRANCH, found ${CURRENT_BRANCH:-unknown}"
    return 0
  fi

  # A commit intent is published durably before the branch CAS. It is the only
  # authority that can recover a process/host crash after update-ref but before
  # the DONE receipt. Validate it independently before inspecting mutable dirty
  # state, because a successful CAS makes the worktree clean on exact retry.
  INTENT="$MISSION_DIR/COMMIT-INTENT-$N.json"
  if [[ -e "$INTENT" || -L "$INTENT" ]]; then
    if [[ ! -f "$INTENT" || -L "$INTENT" ]] || ! validate_commit_intent_schema "$INTENT"; then
      echo "commit intent for request $N is unsafe or malformed" >&2
      return 1
    fi
    if ! jq -e \
        --arg request_sha256 "$REQUEST_SHA256" \
        --arg task_id "$REQUEST_TASK_ID" \
        --argjson generation "$REQUEST_GENERATION" \
        --arg accepted_thread_id "$REQUEST_ACCEPTED_THREAD_ID" \
        --arg outcome_nonce "$REQUEST_OUTCOME_NONCE" \
        --arg branch "$REGISTERED_BRANCH" \
        --argjson paths "$REQUEST_PATHS_SORTED_JSON" \
        --arg diff_sha256 "$REQUEST_DIFF_SHA256" \
        '.request_sha256 == $request_sha256 and .task_id == $task_id and
         .generation == $generation and
         .accepted_thread_id == $accepted_thread_id and
         .outcome_nonce == $outcome_nonce and .branch == $branch and
         (.paths | sort) == $paths and .diff_sha256 == $diff_sha256' \
        "$INTENT" >/dev/null 2>&1; then
      echo "commit intent identity differs from request $N" >&2
      return 1
    fi
    INTENT_PARENT="$(jq -r '.parent_sha' "$INTENT")"
    INTENT_TREE="$(jq -r '.tree_sha' "$INTENT")"
    INTENT_HASH="$(jq -r '.commit_sha' "$INTENT")"
    INTENT_BRANCH="$(jq -r '.branch' "$INTENT")"
    INTENT_PATHS_JSON="$(jq -c '.paths | sort' "$INTENT")"
    INTENT_DIFF="$(jq -r '.diff_sha256' "$INTENT")"
    if ! git -C "$WT" merge-base --is-ancestor "$REGISTERED_BASE" "$INTENT_PARENT" >/dev/null 2>&1; then
      echo "commit intent parent is outside registered ancestry" >&2
      return 1
    fi
    IFS=' ' read -r INTENT_COMMIT_OBJECT INTENT_COMMIT_PARENT INTENT_COMMIT_EXTRA \
      < <(git -C "$WT" rev-list --parents -n 1 "$INTENT_HASH" 2>/dev/null || true)
    [[ "$INTENT_COMMIT_OBJECT" == "$INTENT_HASH" && \
       "$INTENT_COMMIT_PARENT" == "$INTENT_PARENT" && \
       -z "$INTENT_COMMIT_EXTRA" && \
       "$(git -C "$WT" rev-parse --verify "${INTENT_HASH}^{tree}" 2>/dev/null || true)" == "$INTENT_TREE" ]] || {
      echo "commit intent object does not bind its exact parent and tree" >&2
      return 1
    }
    INTENT_MESSAGE="$(git -C "$WT" show -s --format=%B "$INTENT_HASH" 2>/dev/null || true)"
    [[ "$INTENT_MESSAGE" == "$MSG" ]] || {
      echo "commit intent message differs from the bound request" >&2
      return 1
    }
    [[ "$(tree_paths_json "$WT" "$INTENT_PARENT" "$INTENT_HASH" 2>/dev/null || true)" == "$INTENT_PATHS_JSON" && \
       "$(compute_tree_diff_sha256 "$WT" "$INTENT_HASH" "$REQUEST_PATHS_JSON" 2>/dev/null || true)" == "$INTENT_DIFF" ]] || {
      echo "commit intent tree differs from the bound paths or digest" >&2
      return 1
    }
    INTENT_TIP="$(git -C "$WT" rev-parse --verify "refs/heads/${INTENT_BRANCH}^{commit}" 2>/dev/null || true)"
    if [[ "$INTENT_TIP" == "$INTENT_HASH" ]]; then
      [[ "$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" == "$INTENT_HASH" && \
         -z "$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null || true)" ]] || {
        echo "committed intent exists but its worktree has not converged" >&2
        return 1
      }
      HASH="$INTENT_HASH"
      BRANCH="$INTENT_BRANCH"
      write_response DONE "$N" --arg hash "$HASH" --arg branch "$BRANCH" \
        '{protocol_version:$protocol_version,task_id:$task_id,generation:$generation,
          accepted_thread_id:$accepted_thread_id,outcome_nonce:$outcome_nonce,
          request_sha256:$request_sha256,hash:$hash,branch:$branch}' || return 1
      echo "$(date -u +%FT%TZ) RECOVERED DONE $N: $HASH on $BRANCH"
      return 0
    fi
    if [[ "$INTENT_TIP" != "$INTENT_PARENT" ]]; then
      echo "commit intent branch moved beyond both bound tips" >&2
      return 1
    fi
  fi

  while IFS= read -r P; do
    case "$P" in
      /*)                       reject "$N" "absolute path in manifest: $P (use worktree-relative paths)"; return 0 ;;
      *"/../"*|"../"*|*"/.."|"..") reject "$N" "path escapes the worktree: $P"; return 0 ;;
      ".claude/settings.json"|".claude/settings.local.json")
        reject "$N" "refusing to commit Claude settings: $P"
        return 0
        ;;
    esac
    if ! json_array_contains "$ALLOWED_PATHS_JSON" "$P"; then
      reject "$N" "requested path outside approved task DAG: $P"
      return 0
    fi
    if [[ -L "$WT/$P" ]]; then
      reject "$N" "requested path must not be a symlink: $P"
      return 0
    fi
    if [[ -e "$WT/$P" && ! -f "$WT/$P" ]]; then
      reject "$N" "requested path must be a regular file or tracked deletion: $P"
      return 0
    fi
    if [[ ! -e "$WT/$P" && -z "$(git -C "$WT" status --porcelain -- "$P" 2>/dev/null)" ]]; then
      reject "$N" "path has no changes and does not exist: $P"
      return 0
    fi
  done < <(jq -r '.paths[]' "$REQ")

  # Enforce both coordinator scope and request scope independently.
  while IFS= read -r -d '' DIRTY_PATH; do
    if ! json_array_contains "$ALLOWED_PATHS_JSON" "$DIRTY_PATH"; then
      SCOPE_EXTRA="${SCOPE_EXTRA}${DIRTY_PATH} "
    fi
    if ! json_array_contains "$REQUEST_PATHS_JSON" "$DIRTY_PATH"; then
      REQUEST_EXTRA="${REQUEST_EXTRA}${DIRTY_PATH} "
    fi
  done < <(dirty_paths "$WT")
  if [[ -n "$SCOPE_EXTRA" ]]; then
    reject "$N" "worktree has dirty paths outside approved task DAG: $SCOPE_EXTRA"
    return 0
  fi
  if [[ -n "$REQUEST_EXTRA" ]]; then
    reject "$N" "worktree has changes outside the request: ${REQUEST_EXTRA}— include them or split into another request"
    return 0
  fi

  ACTUAL_DIFF="$(compute_diff_sha256 "$WT" "$REQUEST_PATHS_JSON")" || {
    reject "$N" "could not compute canonical diff_sha256"
    return 0
  }
  if [[ "$ACTUAL_DIFF" != "$REQUEST_DIFF_SHA256" ]]; then
    reject "$N" "diff_sha256 does not match current requested path bytes"
    return 0
  fi

  if ! broker_test_hook after-validation; then
    reject "$N" "after-validation test hook failed"
    return 0
  fi
  if [[ "$(request_sha256 "$REQ")" != "$REQUEST_SHA256" ]]; then
    reject "$N" "request bytes changed during broker validation"
    return 0
  fi
  refresh_control_authority || return 1
  if [[ "$REQUEST_GENERATION" != "$CONTROL_GENERATION" ||
        "$REQUEST_ACCEPTED_THREAD_ID" != "$CONTROL_ACCEPTED_THREAD_ID" ||
        "$REQUEST_OUTCOME_NONCE" != "$CONTROL_OUTCOME_NONCE" ]]; then
    reject "$N" "coordinator task authority changed during broker validation"
    return 0
  fi
  if ! cmp -s "$MANIFEST" "$WORKER_MANIFEST"; then
    reject "$N" "worker manifest changed during broker validation"
    return 0
  fi

  if ! broker_test_hook before-stage; then
    reject "$N" "before-stage test hook failed"
    return 0
  fi
  PARENT_HASH="$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  if [[ -z "$PARENT_HASH" ||
        "$(git -C "$WT" rev-parse --verify "refs/heads/${REGISTERED_BRANCH}^{commit}" 2>/dev/null || true)" != "$PARENT_HASH" ]]; then
    reject "$N" "child branch tip changed before staging"
    return 0
  fi
  if ! OUT="$(cd "$WT" && printf '%s' "$REQUEST_PATHS_JSON" | jq -r '.[]' | tr '\n' '\0' | xargs -0 git add -- 2>&1)"; then
    reject "$N" "git add failed: $OUT"
    return 0
  fi
  STAGED_PATHS_JSON="$(staged_paths_json "$WT")" || {
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "could not enumerate the staged path set"
    return 0
  }
  if [[ "$STAGED_PATHS_JSON" != "$REQUEST_PATHS_SORTED_JSON" ]]; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "staged path set does not exactly match requested paths"
    return 0
  fi
  INDEX_DIFF="$(compute_index_diff_sha256 "$WT" "$REQUEST_PATHS_JSON")" || {
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "staged index contains a non-regular path or unreadable blob"
    return 0
  }
  if [[ "$INDEX_DIFF" != "$REQUEST_DIFF_SHA256" ]]; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "staged index bytes do not match diff_sha256"
    return 0
  fi
  TREE_SHA="$(git -C "$WT" write-tree 2>/dev/null)" || {
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "could not write the verified index tree"
    return 0
  }
  TREE_PATHS_JSON="$(tree_paths_json "$WT" "$PARENT_HASH" "$TREE_SHA")" || {
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "could not enumerate the verified tree path set"
    return 0
  }
  if [[ "$TREE_PATHS_JSON" != "$REQUEST_PATHS_SORTED_JSON" ]]; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "verified tree path set does not exactly match requested paths"
    return 0
  fi
  TREE_DIFF="$(compute_tree_diff_sha256 "$WT" "$TREE_SHA" "$REQUEST_PATHS_JSON")" || {
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "could not compute the verified tree digest"
    return 0
  }
  if [[ "$TREE_DIFF" != "$REQUEST_DIFF_SHA256" ]]; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "verified tree bytes do not match diff_sha256"
    return 0
  fi
  if [[ -n "$INTENT_HASH" ]]; then
    [[ "$INTENT_PARENT" == "$PARENT_HASH" && "$INTENT_TREE" == "$TREE_SHA" && \
       "$INTENT_BRANCH" == "$REGISTERED_BRANCH" && \
       "$INTENT_PATHS_JSON" == "$REQUEST_PATHS_SORTED_JSON" && \
       "$INTENT_DIFF" == "$REQUEST_DIFF_SHA256" ]] || {
      echo "existing commit intent no longer matches the verified index" >&2
      return 1
    }
    HASH="$INTENT_HASH"
  else
    if ! HASH="$(printf '%s\n' "$MSG" | git -C "$WT" -c core.hooksPath=/dev/null commit-tree "$TREE_SHA" -p "$PARENT_HASH" 2>/dev/null)"; then
      git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
      reject "$N" "could not create a commit from the verified tree"
      return 0
    fi
    publish_commit_intent "$INTENT" "$PARENT_HASH" "$TREE_SHA" "$HASH" \
      "$REGISTERED_BRANCH" "$REQUEST_PATHS_SORTED_JSON" "$REQUEST_DIFF_SHA256" || {
      git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
      echo "could not durably publish commit intent for request $N" >&2
      return 1
    }
  fi
  if ! git -C "$WT" -c core.hooksPath=/dev/null update-ref -m "orchestrator commit broker" \
      "refs/heads/$REGISTERED_BRANCH" "$HASH" "$PARENT_HASH" >/dev/null 2>&1; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "child branch changed before verified commit publication"
    return 0
  fi
  if [[ "${ORC_COMMIT_BROKER_TEST_FAIL_AFTER_UPDATE_REF:-}" == 1 ]]; then
    echo "injected interruption after commit broker update-ref" >&2
    return 1
  fi
  BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  COMMITTED_TREE="$(git -C "$WT" rev-parse --verify "${HASH}^{tree}" 2>/dev/null || true)"
  COMMITTED_PATHS_JSON="$(tree_paths_json "$WT" "$PARENT_HASH" "$HASH")" || return 1
  COMMITTED_DIFF="$(compute_tree_diff_sha256 "$WT" "$HASH" "$REQUEST_PATHS_JSON")" || return 1
  if [[ "$BRANCH" != "$REGISTERED_BRANCH" ||
        "$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" != "$HASH" ||
        "$COMMITTED_TREE" != "$TREE_SHA" ||
        "$COMMITTED_PATHS_JSON" != "$REQUEST_PATHS_SORTED_JSON" ||
        "$COMMITTED_DIFF" != "$REQUEST_DIFF_SHA256" ]]; then
    echo "verified commit publication changed before DONE for request $N" >&2
    return 1
  fi
  write_response DONE "$N" --arg hash "$HASH" --arg branch "$BRANCH" \
    '{protocol_version:$protocol_version,task_id:$task_id,generation:$generation,
      accepted_thread_id:$accepted_thread_id,outcome_nonce:$outcome_nonce,
      request_sha256:$request_sha256,hash:$hash,branch:$branch}' || {
    echo "committed $HASH but could not publish COMMIT-DONE-$N.json" >&2
    return 1
  }
  echo "$(date -u +%FT%TZ) DONE $N: $HASH on $BRANCH"
}

process_request() { # <request file>
  local rc
  acquire_shared_lifecycle_lock || {
    echo "shared coordinator lifecycle lock is unsafe" >&2
    return 1
  }
  if ! acquire_broker_lock; then
    echo "coordinator commit broker lock is unsafe: $BROKER_LOCK_FILE" >&2
    release_shared_lifecycle_lock
    return 1
  fi
  process_request_transaction "$@"
  rc=$?
  release_broker_lock
  release_shared_lifecycle_lock
  return "$rc"
}

while :; do
  for REQ in "$MISSION_DIR"/COMMIT-REQUEST-*.json; do
    [[ -e "$REQ" ]] || continue
    process_request "$REQ" || exit 1
  done
  if [[ "$ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
