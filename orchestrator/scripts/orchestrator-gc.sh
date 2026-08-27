#!/usr/bin/env bash
# Garbage collector for completed orchestrator missions.
#
#   orchestrator-gc.sh --hub <hub dir> [--mission <slug>] [--clean]
#
# Default is report-only. --clean removes exact manifest-recorded parent and
# integrated orc-task/* child resources. Remote deletion is attempted only
# after a successful exact remote-state check. Unsafe and nonterminal resources
# are preserved; transient child failures become retriable cleanup_pending.

set -uo pipefail

GC_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

HUB=""
CLEAN=0
MISSION_FILTER=""
FOUND=0
ERRORS=0
GC_LOCK_FILE=""
GC_LOCK_CANDIDATE=""
GC_LOCK_OWNED=0
GC_LOCK_CANDIDATE_OWNED=0
GC_LOCK_PUBLISH_INTENT=0
GC_LOCK_TOKEN=""
GC_GUARD_DIR=""
GC_GUARD_TOKEN=""
GC_GUARD_OWNED=0

usage() {
  echo "usage: orchestrator-gc.sh --hub <hub dir> [--mission <slug>] [--clean]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      HUB="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --mission)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      MISSION_FILTER="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

while [[ "$HUB" != "/" && "$HUB" == */ ]]; do
  HUB="${HUB%/}"
done
case "$HUB" in
  */./*|*/.|*/../*|*/..) usage; exit 1 ;;
esac
if [[ -z "$HUB" || ! -d "$HUB" || -L "$HUB" ]]; then
  usage
  exit 1
fi
HUB="$(cd "$HUB" && pwd -P)" || {
  usage
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required for guarded GC authority publication" >&2
  exit 1
}

note() {
  FOUND=1
  echo "$1"
}

problem() {
  ERRORS=$((ERRORS + 1))
  echo "  refused: $1" >&2
}

gc_valid_lock_token() {
  case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

if [[ -n "$MISSION_FILTER" ]] && ! gc_valid_lock_token "$MISSION_FILTER"; then
  echo "invalid mission filter: $MISSION_FILTER" >&2
  usage
  exit 1
fi

gc_pid_is_live() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'
}

gc_guard_operation() {
  python3 - "$1" "$GC_GUARD_DIR" "$$" "$GC_GUARD_TOKEN" <<'PY'
import os, re, stat, sys
operation, guard, pid, token = sys.argv[1:]
expected=(pid+"\t"+token+"\n").encode("ascii"); parent=os.path.dirname(guard) or "."
candidate=guard+".candidate."+pid+"."+token
flags=os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0)
def syncdir(path):
    f=os.open(path,flags)
    try: os.fsync(f)
    finally: os.close(f)
def prepare():
    if os.path.lexists(candidate): raise SystemExit(1)
    os.mkdir(candidate,0o700); d=os.open(candidate,flags)
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
    os.rename(candidate,guard); syncdir(parent)
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
    if (now.st_dev,now.st_ino)!=(before.st_dev,before.st_ino) or (current.st_dev,current.st_ino)!=(before.st_dev,before.st_ino): os.close(d); raise SystemExit(1)
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
    os.unlink("owner",dir_fd=d); os.fsync(d); current=os.lstat(guard)
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

gc_acquire_guard() {
  GC_GUARD_DIR="$GC_LOCK_FILE.guard"
  GC_GUARD_TOKEN="$RANDOM.$(date +%s).guard"
  gc_guard_operation acquire || return 1
  GC_GUARD_OWNED=1
}

gc_release_guard() {
  [[ "$GC_GUARD_OWNED" -eq 1 ]] || return 0
  gc_guard_operation release || return 1
  GC_GUARD_OWNED=0
}

gc_guarded_remove_stale_lock() {
  local stale_candidate="$1" stale_pid="$2" stale_token="$3"
  python3 - "$GC_LOCK_FILE" "$stale_candidate" "$stale_pid" "$stale_token" <<'PY'
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

replacement = os.environ.get("ORC_GC_STALE_LOCK_TEST_REPLACEMENT")
marker = os.environ.get("ORC_GC_STALE_LOCK_TEST_MARKER")
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

# Exercise the last possible name-race boundary, after the final validation.
final_replacement = os.environ.get("ORC_GC_STALE_LOCK_TEST_FINAL_REPLACEMENT")
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
    # The name changed after validation. Restore that exact inode with a
    # no-clobber hard link; never unlink the replacement on this failure path.
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

gc_release_lifecycle_lock() {
  local ok=1
  if [[ "$GC_GUARD_OWNED" -eq 0 && ( "$GC_LOCK_PUBLISH_INTENT" -eq 1 || "$GC_LOCK_CANDIDATE_OWNED" -eq 1 ) ]]; then
    gc_acquire_guard || return 1
  fi
  if [[ "$GC_LOCK_PUBLISH_INTENT" -eq 1 ]]; then
    if [[ -f "$GC_LOCK_FILE" && ! -L "$GC_LOCK_FILE" && \
      -f "$GC_LOCK_CANDIDATE" && ! -L "$GC_LOCK_CANDIDATE" && \
      "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]]; then
      if gc_guarded_remove_stale_lock "$GC_LOCK_CANDIDATE" "$$" "$GC_LOCK_TOKEN"; then
        GC_LOCK_OWNED=0
        GC_LOCK_PUBLISH_INTENT=0
        GC_LOCK_CANDIDATE_OWNED=0
      else
        ok=0
      fi
    elif [[ "$GC_LOCK_OWNED" -eq 1 ]]; then
      ok=0
    else
      GC_LOCK_PUBLISH_INTENT=0
    fi
  fi
  if [[ "$GC_LOCK_CANDIDATE_OWNED" -eq 1 && "$GC_LOCK_OWNED" -eq 0 && "$GC_LOCK_PUBLISH_INTENT" -eq 0 ]]; then
    rm -f -- "$GC_LOCK_CANDIDATE" || ok=0
    GC_LOCK_CANDIDATE_OWNED=0
  fi
  GC_LOCK_FILE=""
  GC_LOCK_CANDIDATE=""
  gc_release_guard || ok=0
  [[ "$ok" -eq 1 ]]
}

gc_acquire_lifecycle_lock() {
  local control="$1" token stale_pid stale_token stale_extra stale_candidate
  local candidate_pid candidate_token candidate_extra
  GC_LOCK_FILE="$control/.task-worktree.lock"
  gc_acquire_guard || return 1
  token="$RANDOM.$(date +%s)"
  GC_LOCK_TOKEN="$token"
  GC_LOCK_CANDIDATE="$GC_LOCK_FILE.$$.$token"
  [[ ! -e "$GC_LOCK_CANDIDATE" && ! -L "$GC_LOCK_CANDIDATE" ]] || return 1
  (umask 077 && printf '%s\t%s\n' "$$" "$token" > "$GC_LOCK_CANDIDATE") || return 1
  GC_LOCK_CANDIDATE_OWNED=1
  GC_LOCK_PUBLISH_INTENT=1
  if ln "$GC_LOCK_CANDIDATE" "$GC_LOCK_FILE" 2>/dev/null; then
    [[ "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]] || return 1
    GC_LOCK_OWNED=1
    gc_release_guard || return 1
    return 0
  fi
  [[ -f "$GC_LOCK_FILE" && ! -L "$GC_LOCK_FILE" ]] || return 1
  stale_pid=""; stale_token=""; stale_extra=""
  IFS=$'\t' read -r stale_pid stale_token stale_extra < "$GC_LOCK_FILE" || return 1
  case "$stale_pid" in ''|*[!0-9]*) return 1 ;; esac
  gc_valid_lock_token "$stale_token" || return 1
  [[ -z "$stale_extra" ]] || return 1
  gc_pid_is_live "$stale_pid" && return 1
  stale_candidate="$GC_LOCK_FILE.$stale_pid.$stale_token"
  [[ -f "$stale_candidate" && ! -L "$stale_candidate" && "$GC_LOCK_FILE" -ef "$stale_candidate" ]] || return 1
  candidate_pid=""; candidate_token=""; candidate_extra=""
  IFS=$'\t' read -r candidate_pid candidate_token candidate_extra < "$stale_candidate" || return 1
  [[ "$candidate_pid" == "$stale_pid" && "$candidate_token" == "$stale_token" && -z "$candidate_extra" ]] || return 1
  gc_pid_is_live "$stale_pid" && return 1
  [[ "$GC_LOCK_FILE" -ef "$stale_candidate" ]] || return 1
  gc_guarded_remove_stale_lock "$stale_candidate" "$stale_pid" "$stale_token" || return 1
  GC_LOCK_PUBLISH_INTENT=1
  ln "$GC_LOCK_CANDIDATE" "$GC_LOCK_FILE" 2>/dev/null || return 1
  [[ "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]] || return 1
  GC_LOCK_OWNED=1
  gc_release_guard || return 1
}

trap 'gc_release_lifecycle_lock >/dev/null 2>&1 || true' EXIT

is_completed_state() {
  case "$1" in
    accepted|done|complete|completed) return 0 ;;
    *) return 1 ;;
  esac
}

file_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

remove_planted_settings() {
  local slug="$1" worktree="$2"
  local settings="$worktree/.claude/settings.local.json"
  local stamp="$HUB/control/$slug/worker-settings.sha256"
  local expected actual

  [[ -e "$settings" || -L "$settings" ]] || return 0
  if [[ ! -f "$settings" || -L "$settings" ]]; then
    problem "$settings is not a regular coordinator-owned file"
    return 1
  fi
  if [[ ! -f "$stamp" ]]; then
    problem "$settings has no coordinator hash stamp"
    return 1
  fi
  expected="$(tr -d '[:space:]' < "$stamp")"
  actual="$(file_hash "$settings")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    problem "$settings differs from the coordinator-owned copy"
    return 1
  fi
  rm -f -- "$settings"
  rmdir "$worktree/.claude" 2>/dev/null || true
}

remote_branch_state() {
  local repo="$1" branch="$2" output status
  output="$(git -C "$repo" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>&1)"
  status=$?
  case "$status" in
    0) echo present ;;
    2) echo absent ;;
    *)
      echo "remote check failed for $branch in $repo: $output" >&2
      echo error
      ;;
  esac
}

child_remote_branch_tip() {
  local repo="$1" branch="$2" output status tip extra
  output="$(git -C "$repo" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>&1)"
  status=$?
  case "$status" in
    0)
      tip=""; extra=""
      IFS=$'\t' read -r tip extra <<< "$output"
      if [[ -z "$tip" || "$tip" == *[!0-9a-fA-F]* || "$extra" != "refs/heads/$branch" || \
        "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" != 1 ]]; then
        echo "remote check returned malformed authority for $branch in $repo" >&2
        echo error
      else
        echo "$tip"
      fi
      ;;
    2) echo absent ;;
    *)
      echo "remote check failed for $branch in $repo: $output" >&2
      echo error
      ;;
  esac
}

write_task_value() {
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

append_cleanup_journal() {
  local path="$1" message="$2"
  python3 - "$path" "$message" <<'PY'
import os
import stat
import sys

path, message = sys.argv[1:]
flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
try:
    descriptor = os.open(path, flags)
except FileNotFoundError:
    try:
        descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        descriptor = os.open(path, flags)
descriptor_stat = os.fstat(descriptor)
path_stat = os.lstat(path)
if (not stat.S_ISREG(descriptor_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode) or
        (descriptor_stat.st_dev, descriptor_stat.st_ino) != (path_stat.st_dev, path_stat.st_ino)):
    os.close(descriptor)
    raise SystemExit(1)
try:
    os.write(descriptor, (message + "\n").encode("utf-8"))
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory = os.path.dirname(path) or "."
directory_descriptor = os.open(directory, os.O_RDONLY)
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
PY
}

remove_regular_authority() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
path_stat = os.lstat(path)
if not stat.S_ISREG(path_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode):
    raise SystemExit(1)
os.unlink(path)
directory = os.path.dirname(path) or "."
descriptor = os.open(directory, os.O_RDONLY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

read_task_value() {
  local path="$1" value extra
  [[ -f "$path" && ! -L "$path" ]] || return 1
  IFS= read -r value < "$path" || [[ -n "${value:-}" ]] || return 1
  IFS= read -r extra < <(sed -n '2p' "$path") || true
  [[ -n "$value" && -z "${extra:-}" ]] || return 1
  printf '%s\n' "$value"
}

child_epoch_matches() {
  local task_control="$1" manifest="$2" expected_generation="$3" expected_manifest_hash="$4"
  local current_generation current_state
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  [[ "$(file_hash "$manifest")" == "$expected_manifest_hash" ]] || return 1
  current_generation="$(read_task_value "$task_control/generation" 2>/dev/null || true)"
  [[ "$current_generation" == "$expected_generation" ]] || return 1
  current_state="$(read_task_value "$task_control/state" 2>/dev/null || true)"
  case "$current_state" in integrated|cleanup_pending|collected) return 0 ;; *) return 1 ;; esac
}

child_cleanup_failure() {
  local task_control="$1" reason="$2"
  problem "$reason"
  if [[ "$CLEAN" -eq 1 ]]; then
    append_cleanup_journal "$task_control/cleanup-journal.log" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ') cleanup failure: $reason" 2>/dev/null || true
    write_task_value "$task_control/state" cleanup_pending 2>/dev/null || true
  fi
  return 1
}

clean_child_task() {
  local mission="$1" task_id="$2" task_control="$3"
  local state manifest worktree branch base repo extra expected_branch
  local integrated_sha parent_worktree child_tip parent_common repo_common child_common
  local actual_parent_tip actual_child_tip branch_tip remote_tip registered=0
  local generation manifest_fingerprint
  local cleanup_intent cleanup_phase cleanup_integrated cleanup_child cleanup_worktree
  local cleanup_branch cleanup_repo cleanup_generation cleanup_manifest_hash cleanup_extra cleanup_record

  state="$(read_task_value "$task_control/state" 2>/dev/null || true)"
  if [[ -z "$state" && ( -e "$task_control/state" || -L "$task_control/state" ) ]]; then
    child_cleanup_failure "$task_control" "$mission/$task_id task state is empty, non-regular, symlinked, or malformed"
    return 1
  fi
  case "$state" in
    collected)
      if [[ ! -e "$task_control/cleanup-intent" && ! -L "$task_control/cleanup-intent" ]]; then
        return 0
      fi
      ;;
    integrated|cleanup_pending) ;;
    *) return 0 ;;
  esac

  # cleanup_pending may belong to the task-window archive step. Git GC cannot
  # satisfy that API obligation and must leave it for coordinator reconciliation.
  if [[ -e "$task_control/task-window-archive-pending" || -L "$task_control/task-window-archive-pending" ]]; then
    return 0
  fi

  manifest="$task_control/worktrees.txt"
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id has no safe coordinator task manifest"
    return 1
  }
  worktree=""; branch=""; base=""; repo=""; extra=""
  IFS=$'\t' read -r worktree branch base repo extra < "$manifest" || {
    child_cleanup_failure "$task_control" "$mission/$task_id manifest cannot be read"
    return 1
  }
  if [[ -z "$worktree" || -z "$branch" || -z "$base" || -z "$repo" || -n "$extra" || \
    "$(wc -l < "$manifest" | tr -d ' ')" != 1 ]]; then
    child_cleanup_failure "$task_control" "$mission/$task_id manifest is malformed"
    return 1
  fi
  expected_branch="orc-task/$mission/$task_id"
  [[ "$branch" == "$expected_branch" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id branch is not the exact manifest namespace"
    return 1
  }

  # A hub copied from another device is not actionable on this machine.
  [[ -d "$repo" && ! -L "$repo" ]] || return 0
  generation="$(read_task_value "$task_control/generation" 2>/dev/null || true)"
  case "$generation" in ''|*[!0-9]*|0)
    child_cleanup_failure "$task_control" "$mission/$task_id generation authority is missing or invalid"
    return 1
    ;;
  esac
  manifest_fingerprint="$(file_hash "$manifest")"
  repo_common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
  [[ -n "$repo_common" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id repository is not a Git repository"
    return 1
  }
  integrated_sha="$(read_task_value "$task_control/integrated_sha" 2>/dev/null || true)"
  parent_worktree="$(read_task_value "$task_control/parent-worktree" 2>/dev/null || true)"
  child_tip="$(read_task_value "$task_control/child_tip" 2>/dev/null || true)"
  [[ -n "$integrated_sha" && -n "$parent_worktree" && -n "$child_tip" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id lacks integration authority records"
    return 1
  }
  [[ "$(git -C "$repo" rev-parse --verify "${base}^{commit}" 2>/dev/null || true)" == "$base" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id manifest base is invalid"
    return 1
  }
  [[ "$(git -C "$repo" rev-parse --verify "${integrated_sha}^{commit}" 2>/dev/null || true)" == "$integrated_sha" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id integrated_sha is invalid"
    return 1
  }
  [[ -d "$parent_worktree" && ! -L "$parent_worktree" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id parent worktree is unavailable"
    return 1
  }
  parent_common="$(cd "$parent_worktree" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
  [[ "$parent_common" == "$repo_common" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id parent belongs to another repository"
    return 1
  }
  [[ "$(git -C "$parent_worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "orc/$mission" ]] || {
    child_cleanup_failure "$task_control" "$mission/$task_id parent is not on the exact mission branch"
    return 1
  }
  actual_parent_tip="$(git -C "$parent_worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  git -C "$repo" merge-base --is-ancestor "$integrated_sha" "$actual_parent_tip" || {
    child_cleanup_failure "$task_control" "$mission/$task_id integration is not contained in the parent tip"
    return 1
  }
  git -C "$repo" merge-base --is-ancestor "$child_tip" "$integrated_sha" || {
    child_cleanup_failure "$task_control" "$mission/$task_id integrated history does not contain the child tip"
    return 1
  }
  git -C "$repo" merge-base --is-ancestor "$base" "$child_tip" || {
    child_cleanup_failure "$task_control" "$mission/$task_id child tip does not descend from the manifest base"
    return 1
  }

  if git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $worktree"; then
    registered=1
  fi
  if [[ -d "$worktree" && ! -L "$worktree" ]]; then
    child_common="$(cd "$worktree" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
    [[ "$registered" -eq 1 && "$child_common" == "$repo_common" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id child worktree registration is not exact"
      return 1
    }
    [[ "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$branch" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id child worktree is on another branch"
      return 1
    }
    actual_child_tip="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
    [[ "$actual_child_tip" == "$child_tip" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id child worktree tip changed"
      return 1
    }
    [[ -z "$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id child worktree is dirty"
      return 1
    }
    note "integrated child worktree ($mission/$task_id): $worktree"
  elif [[ "$registered" -eq 1 || -e "$worktree" || -L "$worktree" ]]; then
    child_cleanup_failure "$task_control" "$mission/$task_id child worktree path is unsafe or missing while registered"
    return 1
  fi

  branch_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)"
  if [[ -n "$branch_tip" ]]; then
    [[ "$branch_tip" == "$child_tip" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id local branch tip changed"
      return 1
    }
    note "integrated child local branch ($mission/$task_id): $branch in $repo"
  fi

  remote_tip="$(child_remote_branch_tip "$repo" "$branch")"
  if [[ "$remote_tip" == error ]]; then
    child_cleanup_failure "$task_control" "$mission/$task_id remote-state check failed; exact resources preserved"
    return 1
  elif [[ "$remote_tip" != absent ]]; then
    [[ "$remote_tip" == "$child_tip" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id remote branch tip changed; exact resources preserved"
      return 1
    }
    note "integrated child remote branch ($mission/$task_id): $branch on origin"
  fi

  [[ "$CLEAN" -eq 1 ]] || return 0
  cleanup_intent="$task_control/cleanup-intent"
  cleanup_record="$(printf 'prepared\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$generation" "$manifest_fingerprint" "$integrated_sha" "$child_tip" "$worktree" "$branch" "$repo")"
  if [[ -e "$cleanup_intent" || -L "$cleanup_intent" ]]; then
    [[ -f "$cleanup_intent" && ! -L "$cleanup_intent" ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id cleanup intent is unsafe"
      return 1
    }
    cleanup_phase=""; cleanup_generation=""; cleanup_manifest_hash=""; cleanup_integrated=""
    cleanup_child=""; cleanup_worktree=""; cleanup_branch=""; cleanup_repo=""; cleanup_extra=""
    IFS=$'\t' read -r cleanup_phase cleanup_generation cleanup_manifest_hash cleanup_integrated \
      cleanup_child cleanup_worktree cleanup_branch cleanup_repo cleanup_extra < "$cleanup_intent" || {
        child_cleanup_failure "$task_control" "$mission/$task_id cleanup intent cannot be read"
        return 1
      }
    if [[ "$cleanup_phase" != prepared && "$cleanup_phase" != resources_collected ]] || \
      [[ "$cleanup_generation" != "$generation" || "$cleanup_manifest_hash" != "$manifest_fingerprint" || \
        "$cleanup_integrated" != "$integrated_sha" || "$cleanup_child" != "$child_tip" || \
        "$cleanup_worktree" != "$worktree" || "$cleanup_branch" != "$branch" || \
        "$cleanup_repo" != "$repo" || -n "$cleanup_extra" || \
        "$(wc -l < "$cleanup_intent" | tr -d ' ')" != 1 ]]; then
      child_cleanup_failure "$task_control" "$mission/$task_id cleanup intent differs from exact authority"
      return 1
    fi
  else
    write_task_value "$cleanup_intent" "$cleanup_record" || {
      child_cleanup_failure "$task_control" "$mission/$task_id cleanup intent publication failed"
      return 1
    }
    cleanup_phase=prepared
  fi
  append_cleanup_journal "$task_control/cleanup-journal.log" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ') cleanup prepared: $branch at $child_tip" || {
    child_cleanup_failure "$task_control" "$mission/$task_id cleanup journal preparation failed"
      return 1
  }
  if [[ -d "$worktree" ]]; then
    child_epoch_matches "$task_control" "$manifest" "$generation" "$manifest_fingerprint" || {
      problem "$mission/$task_id lifecycle epoch changed before worktree deletion; newer resources preserved"
      return 1
    }
    git -C "$repo" worktree remove "$worktree" >/dev/null 2>&1 || {
      child_cleanup_failure "$task_control" "$mission/$task_id exact child worktree removal failed"
      return 1
    }
    echo "  removed child worktree"
  fi
  if [[ -n "$branch_tip" ]]; then
    child_epoch_matches "$task_control" "$manifest" "$generation" "$manifest_fingerprint" || {
      problem "$mission/$task_id lifecycle epoch changed before local branch deletion; newer resources preserved"
      return 1
    }
    git -C "$repo" update-ref -d "refs/heads/$branch" "$child_tip" >/dev/null 2>&1 || {
      child_cleanup_failure "$task_control" "$mission/$task_id exact local branch deletion failed"
      return 1
    }
    echo "  deleted child local branch"
  fi
  if [[ "$remote_tip" != absent ]]; then
    child_epoch_matches "$task_control" "$manifest" "$generation" "$manifest_fingerprint" || {
      problem "$mission/$task_id lifecycle epoch changed before remote branch deletion; newer resources preserved"
      return 1
    }
    git -C "$repo" push --force-with-lease="refs/heads/$branch:$child_tip" \
      origin ":refs/heads/$branch" >/dev/null 2>&1 || {
      child_cleanup_failure "$task_control" "$mission/$task_id exact remote branch deletion failed"
      return 1
    }
    remote_tip="$(child_remote_branch_tip "$repo" "$branch")"
    [[ "$remote_tip" == absent ]] || {
      child_cleanup_failure "$task_control" "$mission/$task_id remote deletion could not be verified"
      return 1
    }
    echo "  deleted child remote branch"
  fi
  child_epoch_matches "$task_control" "$manifest" "$generation" "$manifest_fingerprint" || {
    problem "$mission/$task_id lifecycle epoch changed before resource-collection publication; newer authority preserved"
    return 1
  }
  cleanup_record="$(printf 'resources_collected\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$generation" "$manifest_fingerprint" "$integrated_sha" "$child_tip" "$worktree" "$branch" "$repo")"
  write_task_value "$cleanup_intent" "$cleanup_record" || {
    child_cleanup_failure "$task_control" "$mission/$task_id could not record collected resources"
    return 1
  }
  append_cleanup_journal "$task_control/cleanup-journal.log" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ') resources collected: $branch at $child_tip" || {
    child_cleanup_failure "$task_control" "$mission/$task_id could not journal collected resources"
      return 1
  }
  child_epoch_matches "$task_control" "$manifest" "$generation" "$manifest_fingerprint" || {
    problem "$mission/$task_id lifecycle epoch changed before collected-state publication; newer authority preserved"
    return 1
  }
  write_task_value "$task_control/state" collected || {
    child_cleanup_failure "$task_control" "$mission/$task_id could not record collected state"
    return 1
  }
  append_cleanup_journal "$task_control/cleanup-journal.log" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ') cleanup collected: $branch at $child_tip" || {
    child_cleanup_failure "$task_control" "$mission/$task_id could not journal collected state"
    return 1
  }
  remove_regular_authority "$cleanup_intent" || {
    child_cleanup_failure "$task_control" "$mission/$task_id could not remove completed cleanup intent"
    return 1
  }
  rmdir "$(dirname "$worktree")" 2>/dev/null || true
  return 0
}

parent_cleanup_failure() {
  local control="$1" reason="$2"
  problem "$reason"
  if [[ "$CLEAN" -eq 1 ]]; then
    append_cleanup_journal "$control/parent-cleanup-journal.log" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ') parent cleanup failure: $reason" 2>/dev/null || true
    write_task_value "$control/parent-cleanup-state" cleanup_pending 2>/dev/null || true
  fi
  return 1
}

record_parent_lock_pending() {
  local mission_dir="$1" slug="$2" control="$3" reason="$4"
  local control_root="$HUB/control" control_root_phys control_phys
  local manifest state_file marker mission_state review_state cleanup_state
  local manifest_hash state_hash message

  [[ -f "$mission_dir/state" && ! -L "$mission_dir/state" ]] || return 1
  mission_state="$(read_task_value "$mission_dir/state" 2>/dev/null || true)"
  is_completed_state "$mission_state" || return 1
  [[ -d "$control_root" && ! -L "$control_root" && -d "$control" && ! -L "$control" ]] || return 1
  control_root_phys="$(cd "$control_root" && pwd -P 2>/dev/null || true)"
  control_phys="$(cd "$control" && pwd -P 2>/dev/null || true)"
  [[ -n "$control_root_phys" && -n "$control_phys" && "$control_phys" == "$control" && \
    "$(dirname "$control_phys")" == "$control_root_phys" && "$(basename "$control_phys")" == "$slug" ]] || return 1
  review_state="$(read_task_value "$control/review-resolution" 2>/dev/null || true)"
  [[ "$review_state" == resolved ]] || return 1
  manifest="$control/parent-cleanup-manifest.txt"
  state_file="$control/parent-cleanup-state"
  marker="$control/parent-cleanup-pending-request.json"
  [[ -f "$manifest" && ! -L "$manifest" && -f "$state_file" && ! -L "$state_file" ]] || return 1
  cleanup_state="$(read_task_value "$state_file" 2>/dev/null || true)"
  case "$cleanup_state" in ready|cleanup_pending) ;; *) return 1 ;; esac
  manifest_hash="$(file_hash "$manifest")"
  state_hash="$(file_hash "$state_file")"
  message="$(date -u '+%Y-%m-%dT%H:%M:%SZ') parent cleanup failure: $reason manifest=$manifest_hash"

  python3 - "$manifest" "$manifest_hash" "$state_file" "$state_hash" "$marker" "$message" <<'PY'
import hashlib
import json
import os
import stat
import sys
import tempfile

manifest_path, expected_manifest_hash, state_path, expected_state_hash, marker_path, message = sys.argv[1:]

def digest(value):
    return hashlib.sha256(value).hexdigest()

def regular_snapshot(path):
    path_stat = os.lstat(path)
    if not stat.S_ISREG(path_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode):
        raise SystemExit(1)
    with open(path, "rb") as handle:
        data = handle.read()
    return path_stat, data

def write_all(descriptor, data):
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("guarded pending write made no progress")
        offset += written

manifest_stat, manifest_data = regular_snapshot(manifest_path)
state_stat, state_data = regular_snapshot(state_path)
if digest(manifest_data) != expected_manifest_hash or digest(state_data) != expected_state_hash:
    raise SystemExit(1)
if state_data not in (b"ready\n", b"cleanup_pending\n"):
    raise SystemExit(1)

marker = {
    "version": 1,
    "manifest_sha256": expected_manifest_hash,
    "manifest_dev": manifest_stat.st_dev,
    "manifest_ino": manifest_stat.st_ino,
    "manifest_size": manifest_stat.st_size,
    "state_sha256": expected_state_hash,
    "state_dev": state_stat.st_dev,
    "state_ino": state_stat.st_ino,
    "observed_state": state_data[:-1].decode("utf-8"),
    "reason": message,
}
encoded = (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
directory = os.path.dirname(marker_path) or "."
descriptor, temporary = tempfile.mkstemp(prefix=".parent-cleanup-pending-request.", dir=directory)
try:
    try:
        os.fchmod(descriptor, 0o600)
        write_all(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    replacement = os.environ.get("ORC_PARENT_PENDING_TEST_REPLACE_STATE_WITH")
    if replacement:
        replacement_stat = os.lstat(replacement)
        if not stat.S_ISREG(replacement_stat.st_mode) or stat.S_ISLNK(replacement_stat.st_mode):
            raise SystemExit(1)
        os.replace(replacement, state_path)
        replacement_marker = os.environ.get("ORC_PARENT_PENDING_TEST_REPLACE_MARKER")
        if replacement_marker:
            marker_descriptor = os.open(replacement_marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                write_all(marker_descriptor, b"owner-state-published\n")
                os.fsync(marker_descriptor)
            finally:
                os.close(marker_descriptor)
    manifest_replacement = os.environ.get("ORC_PARENT_PENDING_TEST_REPLACE_MANIFEST_WITH")
    if manifest_replacement:
        replacement_stat = os.lstat(manifest_replacement)
        if not stat.S_ISREG(replacement_stat.st_mode) or stat.S_ISLNK(replacement_stat.st_mode):
            raise SystemExit(1)
        os.replace(manifest_replacement, manifest_path)
        replacement_marker = os.environ.get("ORC_PARENT_PENDING_TEST_REPLACE_MANIFEST_MARKER")
        if replacement_marker:
            marker_descriptor = os.open(replacement_marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                write_all(marker_descriptor, b"owner-manifest-published\n")
                os.fsync(marker_descriptor)
            finally:
                os.close(marker_descriptor)
    try:
        os.link(temporary, marker_path)
    except FileExistsError:
        existing_stat, existing_data = regular_snapshot(marker_path)
        try:
            existing = json.loads(existing_data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise SystemExit(1)
        canonical = (json.dumps(existing, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        if existing_data != canonical:
            raise SystemExit(1)
    else:
        published_stat = os.lstat(marker_path)
        temporary_stat = os.lstat(temporary)
        if (not stat.S_ISREG(published_stat.st_mode) or stat.S_ISLNK(published_stat.st_mode) or
                (published_stat.st_dev, published_stat.st_ino) !=
                (temporary_stat.st_dev, temporary_stat.st_ino)):
            raise SystemExit(1)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)

directory_descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
PY
}

consume_parent_lock_pending() {
  local control="$1"
  local marker="$control/parent-cleanup-pending-request.json"
  local manifest="$control/parent-cleanup-manifest.txt"
  local state_file="$control/parent-cleanup-state"
  local journal="$control/parent-cleanup-journal.log"
  [[ -e "$marker" || -L "$marker" ]] || return 0
  python3 - "$marker" "$manifest" "$state_file" "$journal" <<'PY'
import hashlib
import json
import os
import stat
import sys
import tempfile

marker_path, manifest_path, state_path, journal_path = sys.argv[1:]

def digest(value):
    return hashlib.sha256(value).hexdigest()

def regular_snapshot(path):
    path_stat = os.lstat(path)
    if not stat.S_ISREG(path_stat.st_mode) or stat.S_ISLNK(path_stat.st_mode):
        raise SystemExit(1)
    with open(path, "rb") as handle:
        data = handle.read()
    return path_stat, data

def write_all(descriptor, data):
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("pending request consumption made no progress")
        offset += written

marker_stat, marker_data = regular_snapshot(marker_path)
try:
    marker = json.loads(marker_data.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
expected_keys = {
    "version", "manifest_sha256", "manifest_dev", "manifest_ino", "manifest_size",
    "state_sha256", "state_dev", "state_ino", "observed_state", "reason",
}
canonical = (json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
if marker_data != canonical or set(marker) != expected_keys or marker.get("version") != 1:
    raise SystemExit(1)
if (not isinstance(marker.get("manifest_sha256"), str) or
        not isinstance(marker.get("manifest_dev"), int) or
        not isinstance(marker.get("manifest_ino"), int) or
        not isinstance(marker.get("manifest_size"), int) or marker["manifest_size"] < 0 or
        not isinstance(marker.get("state_sha256"), str) or
        not isinstance(marker.get("state_dev"), int) or
        not isinstance(marker.get("state_ino"), int) or
        marker.get("observed_state") not in ("ready", "cleanup_pending") or
        not isinstance(marker.get("reason"), str) or not marker["reason"]):
    raise SystemExit(1)

manifest_stat, manifest_data = regular_snapshot(manifest_path)
state_stat, state_data = regular_snapshot(state_path)
if state_data not in (b"ready\n", b"cleanup_pending\n", b"collected\n"):
    raise SystemExit(1)
current_manifest_hash = digest(manifest_data)
current_state_hash = digest(state_data)
same_manifest_epoch = (
    current_manifest_hash == marker["manifest_sha256"] and
    manifest_stat.st_dev == marker["manifest_dev"] and
    manifest_stat.st_ino == marker["manifest_ino"] and
    manifest_stat.st_size == marker["manifest_size"]
)
same_state_epoch = (
    current_state_hash == marker["state_sha256"] and
    state_stat.st_dev == marker["state_dev"] and
    state_stat.st_ino == marker["state_ino"]
)
same_observed_epoch = same_manifest_epoch and same_state_epoch

flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
try:
    journal_descriptor = os.open(journal_path, flags)
except FileNotFoundError:
    try:
        journal_descriptor = os.open(journal_path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        journal_descriptor = os.open(journal_path, flags)
journal_descriptor_stat = os.fstat(journal_descriptor)
journal_path_stat = os.lstat(journal_path)
if (not stat.S_ISREG(journal_descriptor_stat.st_mode) or stat.S_ISLNK(journal_path_stat.st_mode) or
        (journal_descriptor_stat.st_dev, journal_descriptor_stat.st_ino) !=
        (journal_path_stat.st_dev, journal_path_stat.st_ino)):
    os.close(journal_descriptor)
    raise SystemExit(1)
consumed_message = (marker["reason"] + " pending-request-consumed current-manifest=" +
                    current_manifest_hash + "\n").encode("utf-8")
try:
    write_all(journal_descriptor, consumed_message)
    os.fsync(journal_descriptor)
finally:
    os.close(journal_descriptor)

state_directory = os.path.dirname(state_path) or "."
if same_observed_epoch and state_data == b"ready\n":
    descriptor, temporary = tempfile.mkstemp(prefix=".parent-cleanup-state.", dir=state_directory)
    try:
        try:
            os.fchmod(descriptor, 0o600)
            write_all(descriptor, b"cleanup_pending\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, state_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

current_marker_stat = os.lstat(marker_path)
if ((current_marker_stat.st_dev, current_marker_stat.st_ino) !=
        (marker_stat.st_dev, marker_stat.st_ino) or
        not stat.S_ISREG(current_marker_stat.st_mode) or stat.S_ISLNK(current_marker_stat.st_mode)):
    raise SystemExit(1)
os.unlink(marker_path)
for directory in {os.path.dirname(journal_path) or ".", state_directory}:
    directory_descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
if not same_manifest_epoch:
    raise SystemExit(3)
PY
}

archive_copy_regular() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import os
import stat
import sys
import tempfile

source, destination = sys.argv[1:]
source_stat = os.lstat(source)
if not stat.S_ISREG(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
    raise SystemExit(1)
with open(source, "rb") as handle:
    data = handle.read()

def digest(value):
    return hashlib.sha256(value).digest()

def read_all(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)

def write_all_verified(descriptor, value):
    maximum = int(os.environ.get("ORC_ARCHIVE_TEST_MAX_WRITE", "0"))
    fail_after = int(os.environ.get("ORC_ARCHIVE_TEST_FAIL_AFTER_BYTES", "0"))
    offset = 0
    while offset < len(value):
        end = min(len(value), offset + maximum) if maximum else len(value)
        written = os.write(descriptor, value[offset:end])
        if written <= 0:
            raise OSError("archive write made no progress")
        offset += written
        if fail_after and offset >= fail_after:
            raise OSError("injected archive write interruption")
    os.fsync(descriptor)
    descriptor_stat = os.fstat(descriptor)
    observed = read_all(descriptor)
    if descriptor_stat.st_size != len(value) or len(observed) != len(value) or digest(observed) != digest(value):
        raise OSError("archive write verification failed")

directory = os.path.dirname(destination) or "."
try:
    destination_stat = os.lstat(destination)
except FileNotFoundError:
    descriptor, temporary = tempfile.mkstemp(prefix=".archive-item.", dir=directory)
    try:
        try:
            os.fchmod(descriptor, 0o600)
            write_all_verified(descriptor, data)
        finally:
            os.close(descriptor)
        os.link(temporary, destination)
        published = os.lstat(destination)
        temporary_stat = os.lstat(temporary)
        if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or
                (published.st_dev, published.st_ino) != (temporary_stat.st_dev, temporary_stat.st_ino)):
            raise OSError("archive publication ownership mismatch")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
else:
    if not stat.S_ISREG(destination_stat.st_mode) or stat.S_ISLNK(destination_stat.st_mode):
        raise SystemExit(1)
    with open(destination, "rb") as handle:
        if handle.read() != data:
            raise SystemExit(1)
published = os.lstat(destination)
if not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or published.st_size != len(data):
    raise SystemExit(1)
with open(destination, "rb") as handle:
    published_data = handle.read()
if len(published_data) != len(data) or digest(published_data) != digest(data):
    raise SystemExit(1)
descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

archive_replace_regular() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import os
import stat
import sys
import tempfile

source, destination = sys.argv[1:]
source_stat = os.lstat(source)
if not stat.S_ISREG(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
    raise SystemExit(1)
with open(source, "rb") as handle:
    data = handle.read()

def digest(value):
    return hashlib.sha256(value).digest()

def read_all(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)

def write_all_verified(descriptor, value):
    maximum = int(os.environ.get("ORC_ARCHIVE_TEST_MAX_WRITE", "0"))
    fail_after = int(os.environ.get("ORC_ARCHIVE_TEST_FAIL_AFTER_BYTES", "0"))
    offset = 0
    while offset < len(value):
        end = min(len(value), offset + maximum) if maximum else len(value)
        written = os.write(descriptor, value[offset:end])
        if written <= 0:
            raise OSError("archive write made no progress")
        offset += written
        if fail_after and offset >= fail_after:
            raise OSError("injected archive write interruption")
    os.fsync(descriptor)
    descriptor_stat = os.fstat(descriptor)
    observed = read_all(descriptor)
    if descriptor_stat.st_size != len(value) or len(observed) != len(value) or digest(observed) != digest(value):
        raise OSError("archive write verification failed")

directory = os.path.dirname(destination) or "."
try:
    destination_stat = os.lstat(destination)
except FileNotFoundError:
    destination_stat = None
if destination_stat is not None and (
        not stat.S_ISREG(destination_stat.st_mode) or stat.S_ISLNK(destination_stat.st_mode)):
    raise SystemExit(1)
descriptor, temporary = tempfile.mkstemp(prefix=".cleanup-journal.", dir=directory)
try:
    try:
        os.fchmod(descriptor, 0o600)
        write_all_verified(descriptor, data)
    finally:
        os.close(descriptor)
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
published = os.lstat(destination)
if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode) or
        published.st_size != len(data)):
    raise SystemExit(1)
with open(destination, "rb") as handle:
    published_data = handle.read()
if len(published_data) != len(data) or digest(published_data) != digest(data):
    raise SystemExit(1)
descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

verify_parent_version_authority() {
  local control="$1" version="$2"
  python3 - "$control" "$version" <<'PY'
import hashlib
import os
import re
import stat
import sys

control, version = sys.argv[1:]
names = ["approved-design.md", "approved-plan.md", "brief-exec.md"]
if version == "hybrid-0.4":
    names.append("approved-task-dag.json")
elif version != "hybrid-0.3":
    raise SystemExit(1)

def regular(path):
    value = os.lstat(path)
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
        raise SystemExit(1)

manifest = os.path.join(control, "approved.sha256")
regular(manifest)
with open(manifest, "r", encoding="utf-8", newline="") as handle:
    lines = handle.read().splitlines()
if len(lines) != len(names):
    raise SystemExit(1)
for line, name in zip(lines, names):
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
    if not match or match.group(2) != name:
        raise SystemExit(1)
    path = os.path.join(control, name)
    regular(path)
    with open(path, "rb") as handle:
        if hashlib.sha256(handle.read()).hexdigest() != match.group(1):
            raise SystemExit(1)
PY
}

archive_parent_artifacts() {
  local mission_dir="$1" control="$2" slug="$3" mission_version="$4"
  local archive_root="$HUB/archive" archive_dir="$HUB/archive/$slug"
  local design_source plan_source source destination archive_index
  local sources=() destinations=()

  [[ -d "$archive_root" && ! -L "$archive_root" ]] || return 1
  if [[ -e "$archive_dir" || -L "$archive_dir" ]]; then
    [[ -d "$archive_dir" && ! -L "$archive_dir" ]] || return 1
  else
    mkdir "$archive_dir" || return 1
    [[ -d "$archive_dir" && ! -L "$archive_dir" ]] || return 1
  fi

  design_source="$mission_dir/design.md"
  [[ -f "$design_source" && ! -L "$design_source" ]] || design_source="$control/approved-design.md"
  plan_source="$mission_dir/plan.md"
  [[ -f "$plan_source" && ! -L "$plan_source" ]] || plan_source="$control/approved-plan.md"
  sources=(
    "$design_source"
    "$plan_source"
    "$control/approved-design.md"
    "$control/approved-plan.md"
    "$control/brief-exec.md"
    "$control/decisions.md"
    "$mission_dir/report.md"
    "$control/verification.md"
  )
  destinations=(
    "$archive_dir/design.md"
    "$archive_dir/plan.md"
    "$archive_dir/approved-design.md"
    "$archive_dir/approved-plan.md"
    "$archive_dir/brief-exec.md"
    "$archive_dir/DECISIONS.md"
    "$archive_dir/report.md"
    "$archive_dir/verification.md"
  )
  if [[ "$mission_version" == hybrid-0.4 ]]; then
    sources+=("$control/approved-task-dag.json")
    destinations+=("$archive_dir/approved-task-dag.json")
  fi
  for source in "${sources[@]}"; do
    [[ -f "$source" && ! -L "$source" ]] || return 1
  done
  for ((archive_index=0; archive_index < ${#sources[@]}; archive_index++)); do
    source="${sources[$archive_index]}"
    destination="${destinations[$archive_index]}"
    archive_copy_regular "$source" "$destination" || return 1
  done
}

parent_children_are_archived() {
  local control="$1" slug="$2" tasks tasks_phys control_phys
  local task_dir task_phys task_id state thread_id window_state authority
  control_phys="$(cd "$control" && pwd -P 2>/dev/null || true)"
  [[ -n "$control_phys" && "$control_phys" == "$control" ]] || {
    parent_cleanup_failure "$control" "$slug coordinator control path is not exact and canonical"
    return 1
  }
  tasks="$control/tasks"
  if [[ -e "$control/tasks" || -L "$control/tasks" ]]; then
    [[ -d "$control/tasks" && ! -L "$control/tasks" ]] || {
      parent_cleanup_failure "$control" "$slug coordinator task registry is unsafe"
      return 1
    }
  else
    return 0
  fi
  tasks_phys="$(cd "$tasks" && pwd -P 2>/dev/null || true)"
  [[ -n "$tasks_phys" && "$(dirname "$tasks_phys")" == "$control_phys" && \
    "$(basename "$tasks_phys")" == tasks ]] || {
    parent_cleanup_failure "$control" "$slug coordinator task registry is not a direct physical child"
    return 1
  }
  for task_dir in "$tasks"/* "$tasks"/.[!.]* "$tasks"/..?*; do
    [[ -e "$task_dir" || -L "$task_dir" ]] || continue
    task_id="$(basename "$task_dir")"
    gc_valid_lock_token "$task_id" || {
      parent_cleanup_failure "$control" "$slug has a noncanonical child task identity"
      return 1
    }
    [[ -d "$task_dir" && ! -L "$task_dir" ]] || {
      parent_cleanup_failure "$control" "$slug/$task_id registry entry is not an exact directory"
      return 1
    }
    task_phys="$(cd "$task_dir" && pwd -P 2>/dev/null || true)"
    [[ -n "$task_phys" && "$task_dir" == "$tasks/$task_id" && \
      "$(dirname "$task_phys")" == "$tasks_phys" && \
      "$(basename "$task_phys")" == "$task_id" ]] || {
      parent_cleanup_failure "$control" "$slug/$task_id registry entry escapes exact direct-child authority"
      return 1
    }
    if [[ -e "$task_dir/unresolved-rework" || -L "$task_dir/unresolved-rework" ]]; then
      parent_cleanup_failure "$control" "$slug/$task_id still has unresolved rework"
      return 1
    fi
    for authority in state accepted-thread-id task-window-state; do
      [[ -f "$task_dir/$authority" && ! -L "$task_dir/$authority" ]] || {
        parent_cleanup_failure "$control" "$slug/$task_id $authority authority is missing or unsafe"
        return 1
      }
    done
    state="$(read_task_value "$task_dir/state" 2>/dev/null || true)"
    [[ "$state" == collected ]] || {
      parent_cleanup_failure "$control" "$slug/$task_id is nonterminal or not fully collected"
      return 1
    }
    if [[ -e "$task_dir/task-window-archive-pending" || -L "$task_dir/task-window-archive-pending" ]]; then
      parent_cleanup_failure "$control" "$slug/$task_id task window archival is pending"
      return 1
    fi
    thread_id="$(read_task_value "$task_dir/accepted-thread-id" 2>/dev/null || true)"
    window_state="$(read_task_value "$task_dir/task-window-state" 2>/dev/null || true)"
    gc_valid_lock_token "$thread_id" || {
      parent_cleanup_failure "$control" "$slug/$task_id accepted child thread identity is malformed"
      return 1
    }
    [[ "$window_state" == archived ]] || {
      parent_cleanup_failure "$control" "$slug/$task_id accepted task window is not archived"
      return 1
    }
  done
}

parent_epoch_matches() {
  local control="$1" manifest="$2" manifest_hash="$3" state
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  [[ "$(file_hash "$manifest")" == "$manifest_hash" ]] || return 1
  state="$(read_task_value "$control/parent-cleanup-state" 2>/dev/null || true)"
  case "$state" in ready|cleanup_pending|collected) return 0 ;; *) return 1 ;; esac
}

parent_target_ref_matches() {
  local repo="$1" target="$2" parent_tip="$3" recorded_target_tip="$4" current_target_tip
  [[ "$(git -C "$repo" rev-parse --verify "${recorded_target_tip}^{commit}" 2>/dev/null || true)" == \
    "$recorded_target_tip" ]] || return 1
  current_target_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${target}^{commit}" 2>/dev/null || true)"
  [[ -n "$current_target_tip" ]] || return 1
  git -C "$repo" merge-base --is-ancestor "$parent_tip" "$recorded_target_tip" || return 1
  git -C "$repo" merge-base --is-ancestor "$recorded_target_tip" "$current_target_tip" || return 1
  git -C "$repo" merge-base --is-ancestor "$parent_tip" "$current_target_tip"
}

parent_target_epoch_matches() {
  local control="$1" manifest="$2" manifest_hash="$3" snapshot="$4" snapshot_hash="$5"
  local repo="$6" target="$7" parent_tip="$8" recorded_target_tip="$9"
  parent_epoch_matches "$control" "$manifest" "$manifest_hash" || return 1
  [[ -f "$snapshot" && ! -L "$snapshot" && "$(file_hash "$snapshot")" == "$snapshot_hash" ]] || return 1
  parent_target_ref_matches "$repo" "$target" "$parent_tip" "$recorded_target_tip"
}

clean_exact_parent_mission() {
  local mission_dir="$1" slug="$2"
  local control="$HUB/control/$slug"
  local control_root="$HUB/control" control_root_phys control_phys
  local mission_state review_state cleanup_state manifest manifest_hash intent intent_value pending_request_rc
  local target_snapshot target_snapshot_hash snapshot_stage snapshot_count snapshot_lines snapshot_tip
  local snapshot_repo snapshot_target snapshot_parent snapshot_extra
  local worktree branch parent_tip repo target extra expected_branch
  local normalized_target_ref normalized_parent_ref resolved_target_ref
  local pr_metadata pr_repo pr_target pr_status pr_id pr_merge pr_extra pr_line
  local repo_phys repo_common worktree_common actual_tip target_tip local_tip remote_tip registered
  local archive_dir="$HUB/archive/$slug" row_count=0 index
  local mission_version classifier
  local worktrees=() branches=() tips=() repos=() targets=() target_tips=()
  local epoch_target_tips=() local_tips=() remote_tips=()

  [[ -d "$control_root" && ! -L "$control_root" ]] || {
    problem "$slug coordinator control root is unsafe"
    return 1
  }
  control_root_phys="$(cd "$control_root" && pwd -P 2>/dev/null || true)"
  if [[ -e "$control" || -L "$control" ]]; then
    [[ -d "$control" && ! -L "$control" ]] || {
      problem "$slug coordinator control entry is unsafe"
      return 1
    }
  else
    return 0
  fi
  control_phys="$(cd "$control" && pwd -P 2>/dev/null || true)"
  [[ -n "$control_phys" && "$(dirname "$control_phys")" == "$control_root_phys" && \
    "$(basename "$control_phys")" == "$slug" && "$control_phys" == "$control" ]] || {
    problem "$slug coordinator control entry is not an exact direct physical child"
    return 1
  }
  manifest="$control/parent-cleanup-manifest.txt"
  [[ -e "$manifest" || -L "$manifest" ]] || return 0
  [[ -f "$mission_dir/state" && ! -L "$mission_dir/state" ]] || {
    parent_cleanup_failure "$control" "$slug mission state is missing or unsafe"
    return 1
  }
  mission_state="$(read_task_value "$mission_dir/state" 2>/dev/null || true)"
  is_completed_state "$mission_state" || return 0
  review_state="$(read_task_value "$control/review-resolution" 2>/dev/null || true)"
  [[ "$review_state" == resolved ]] || {
    parent_cleanup_failure "$control" "$slug final review is not durably resolved"
    return 1
  }
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    parent_cleanup_failure "$control" "$slug parent cleanup manifest is missing or unsafe"
    return 1
  }
  classifier="$GC_SCRIPT_DIR/classify-mission-version.sh"
  [[ -x "$classifier" ]] || {
    parent_cleanup_failure "$control" "$slug mission classifier is unavailable"
    return 1
  }
  mission_version="$($classifier --mission-dir "$mission_dir" --control-dir "$control" 2>/dev/null)" || {
    parent_cleanup_failure "$control" "$slug mission version authority is partial, contradictory, or unsafe"
    return 1
  }
  case "$mission_version" in
    hybrid-0.3|hybrid-0.4) ;;
    *)
      parent_cleanup_failure "$control" "$slug parent DAG GC supports only classified Hybrid 0.3 or 0.4 authority"
      return 1
      ;;
  esac
  verify_parent_version_authority "$control" "$mission_version" || {
    parent_cleanup_failure "$control" "$slug approved authority manifest is incomplete, noncanonical, or changed"
    return 1
  }
  if [[ "$CLEAN" -eq 1 ]]; then
    pending_request_rc=0
    consume_parent_lock_pending "$control" || pending_request_rc=$?
    case "$pending_request_rc" in
      0) ;;
      3)
        problem "$slug stale parent cleanup pending request was consumed; exact retry required"
        return 1
        ;;
      *)
        problem "$slug parent cleanup pending request is unsafe or could not be consumed under lock"
        return 1
        ;;
    esac
  fi
  cleanup_state="$(read_task_value "$control/parent-cleanup-state" 2>/dev/null || true)"
  case "$cleanup_state" in
    collected) return 0 ;;
    ready|cleanup_pending) ;;
    *)
      parent_cleanup_failure "$control" "$slug parent cleanup state is missing or invalid"
      return 1
      ;;
  esac
  if [[ "$mission_version" == hybrid-0.4 ]]; then
    parent_children_are_archived "$control" "$slug" || return 1
  fi
  manifest_hash="$(file_hash "$manifest")"
  pr_metadata="$control/pr-merge-metadata"
  if [[ -e "$pr_metadata" || -L "$pr_metadata" ]]; then
    [[ -f "$pr_metadata" && ! -L "$pr_metadata" ]] || {
      parent_cleanup_failure "$control" "$slug PR merge metadata is unsafe"
      return 1
    }
  fi

  while IFS=$'\t' read -r worktree branch parent_tip repo target extra || [[ -n "${worktree:-}" ]]; do
    row_count=$((row_count + 1))
    if [[ -z "$worktree" || -z "$branch" || -z "$parent_tip" || -z "$repo" || \
      -z "$target" || -n "$extra" ]]; then
      parent_cleanup_failure "$control" "$slug parent cleanup manifest is malformed"
      return 1
    fi
    expected_branch="orc/$slug"
    [[ "$branch" == "$expected_branch" ]] || {
      parent_cleanup_failure "$control" "$slug parent branch is not the exact manifest namespace"
      return 1
    }
    case "$parent_tip" in ''|*[!0-9a-fA-F]*)
      parent_cleanup_failure "$control" "$slug recorded parent tip is invalid"
      return 1
      ;;
    esac
    git -C "$repo" check-ref-format "refs/heads/$target" >/dev/null 2>&1 || {
      parent_cleanup_failure "$control" "$slug target branch is invalid"
      return 1
    }
    normalized_target_ref="$(git -C "$repo" check-ref-format --normalize "refs/heads/$target" 2>/dev/null || true)"
    normalized_parent_ref="$(git -C "$repo" check-ref-format --normalize "refs/heads/$branch" 2>/dev/null || true)"
    resolved_target_ref="$(git -C "$repo" symbolic-ref --quiet "$normalized_target_ref" 2>/dev/null || true)"
    if [[ -n "$resolved_target_ref" ]]; then
      resolved_target_ref="$(git -C "$repo" check-ref-format --normalize "$resolved_target_ref" 2>/dev/null || true)"
    else
      resolved_target_ref="$normalized_target_ref"
    fi
    if [[ -z "$normalized_target_ref" || -z "$normalized_parent_ref" || \
      -z "$resolved_target_ref" || "$normalized_target_ref" == "$normalized_parent_ref" || \
      "$resolved_target_ref" == "$normalized_parent_ref" ]]; then
      parent_cleanup_failure "$control" "$slug target branch aliases the mission-owned parent ref"
      return 1
    fi
    [[ -d "$repo" && ! -L "$repo" ]] || {
      parent_cleanup_failure "$control" "$slug manifest repository is unavailable"
      return 1
    }
    repo_phys="$(cd "$repo" && pwd -P 2>/dev/null || true)"
    [[ "$repo_phys" == "$repo" ]] || {
      parent_cleanup_failure "$control" "$slug repository path is not exact and canonical"
      return 1
    }
    repo_common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
    [[ -n "$repo_common" ]] || {
      parent_cleanup_failure "$control" "$slug manifest repository is not Git"
      return 1
    }
    [[ "$(git -C "$repo" rev-parse --verify "${parent_tip}^{commit}" 2>/dev/null || true)" == "$parent_tip" ]] || {
      parent_cleanup_failure "$control" "$slug recorded parent tip does not resolve exactly"
      return 1
    }
    target_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${target}^{commit}" 2>/dev/null || true)"
    if [[ -z "$target_tip" ]] || ! git -C "$repo" merge-base --is-ancestor "$parent_tip" "$target_tip"; then
      parent_cleanup_failure "$control" "$slug recorded parent tip is not contained in the target branch"
      return 1
    fi
    if [[ -f "$pr_metadata" ]]; then
      pr_line="$(sed -n "${row_count}p" "$pr_metadata")"
      pr_repo=""; pr_target=""; pr_status=""; pr_id=""; pr_merge=""; pr_extra=""
      IFS=$'\t' read -r pr_repo pr_target pr_status pr_id pr_merge pr_extra <<< "$pr_line"
      if [[ "$pr_repo" != "$repo" || "$pr_target" != "$target" || \
        "$pr_status" != merged || -z "$pr_id" || -z "$pr_merge" || -n "$pr_extra" || \
        "$(git -C "$repo" rev-parse --verify "${pr_merge}^{commit}" 2>/dev/null || true)" != "$pr_merge" ]] || \
        ! git -C "$repo" merge-base --is-ancestor "$parent_tip" "$pr_merge" || \
        ! git -C "$repo" merge-base --is-ancestor "$pr_merge" "$target_tip"; then
        parent_cleanup_failure "$control" "$slug PR merge metadata did not verify as additional evidence"
        return 1
      fi
    fi

    registered=0
    git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $worktree" && registered=1
    if [[ -d "$worktree" && ! -L "$worktree" ]]; then
      worktree_common="$(cd "$worktree" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
      [[ "$registered" -eq 1 && "$worktree_common" == "$repo_common" ]] || {
        parent_cleanup_failure "$control" "$slug parent worktree registration is not exact"
        return 1
      }
      [[ "$(cd "$worktree" && pwd -P 2>/dev/null || true)" == "$worktree" ]] || {
        parent_cleanup_failure "$control" "$slug parent worktree path is not exact and canonical"
        return 1
      }
      [[ "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$branch" ]] || {
        parent_cleanup_failure "$control" "$slug parent worktree is on another branch"
        return 1
      }
      actual_tip="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
      [[ "$actual_tip" == "$parent_tip" ]] || {
        parent_cleanup_failure "$control" "$slug parent worktree tip differs from recorded authority"
        return 1
      }
      [[ -z "$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" ]] || {
        parent_cleanup_failure "$control" "$slug parent worktree is dirty"
        return 1
      }
      note "merged parent worktree ($slug): $worktree"
    elif [[ "$registered" -eq 1 || -e "$worktree" || -L "$worktree" ]]; then
      parent_cleanup_failure "$control" "$slug parent worktree path is unsafe or missing while registered"
      return 1
    fi

    local_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)"
    [[ -z "$local_tip" || "$local_tip" == "$parent_tip" ]] || {
      parent_cleanup_failure "$control" "$slug local parent branch tip changed"
      return 1
    }
    [[ -z "$local_tip" ]] || note "merged parent local branch ($slug): $branch in $repo"
    remote_tip="$(child_remote_branch_tip "$repo" "$branch")"
    if [[ "$remote_tip" == error ]]; then
      parent_cleanup_failure "$control" "$slug remote-state check failed; exact parent resources preserved"
      return 1
    elif [[ "$remote_tip" != absent && "$remote_tip" != "$parent_tip" ]]; then
      parent_cleanup_failure "$control" "$slug remote parent branch tip changed; exact resources preserved"
      return 1
    elif [[ "$remote_tip" != absent ]]; then
      note "merged parent remote branch ($slug): $branch on origin"
    fi
    worktrees+=("$worktree")
    branches+=("$branch")
    tips+=("$parent_tip")
    repos+=("$repo")
    targets+=("$target")
    target_tips+=("$target_tip")
    local_tips+=("$local_tip")
    remote_tips+=("$remote_tip")
  done < "$manifest"
  [[ "$row_count" -gt 0 && "$row_count" -eq "$(wc -l < "$manifest" | tr -d ' ')" ]] || {
    parent_cleanup_failure "$control" "$slug parent cleanup manifest has blank or malformed rows"
    return 1
  }
  if [[ -f "$pr_metadata" && "$row_count" -ne "$(wc -l < "$pr_metadata" | tr -d ' ')" ]]; then
    parent_cleanup_failure "$control" "$slug PR merge metadata row count differs from exact parent authority"
    return 1
  fi

  [[ "$CLEAN" -eq 1 ]] || return 0

  target_snapshot="$control/parent-cleanup-targets.txt"
  if [[ -e "$target_snapshot" || -L "$target_snapshot" ]]; then
    [[ -f "$target_snapshot" && ! -L "$target_snapshot" ]] || {
      parent_cleanup_failure "$control" "$slug parent target snapshot is unsafe"
      return 1
    }
  else
    snapshot_stage="$(mktemp "$control/.parent-cleanup-targets.XXXXXX")" || {
      parent_cleanup_failure "$control" "$slug parent target snapshot staging failed"
      return 1
    }
    chmod 0600 "$snapshot_stage" || {
      rm -f -- "$snapshot_stage"
      parent_cleanup_failure "$control" "$slug parent target snapshot staging could not be secured"
      return 1
    }
    for ((index=0; index < row_count; index++)); do
      printf '%s\t%s\t%s\t%s\n' "${repos[$index]}" "${targets[$index]}" \
        "${tips[$index]}" "${target_tips[$index]}" >> "$snapshot_stage" || {
        rm -f -- "$snapshot_stage"
        parent_cleanup_failure "$control" "$slug parent target snapshot staging write failed"
        return 1
      }
    done
    if ! archive_copy_regular "$snapshot_stage" "$target_snapshot"; then
      rm -f -- "$snapshot_stage"
      parent_cleanup_failure "$control" "$slug parent target snapshot publication failed"
      return 1
    fi
    rm -f -- "$snapshot_stage"
  fi

  snapshot_count=0
  while IFS=$'\t' read -r snapshot_repo snapshot_target snapshot_parent snapshot_tip snapshot_extra || \
    [[ -n "${snapshot_repo:-}" ]]; do
    index="$snapshot_count"
    if [[ "$index" -ge "$row_count" ]]; then
      parent_cleanup_failure "$control" "$slug parent target snapshot has an unexpected extra row"
      return 1
    fi
    if [[ "$snapshot_repo" != "${repos[$index]}" || \
      "$snapshot_target" != "${targets[$index]}" || "$snapshot_parent" != "${tips[$index]}" || \
      -z "$snapshot_tip" || -n "$snapshot_extra" ]] || \
      ! parent_target_ref_matches "${repos[$index]}" "${targets[$index]}" \
        "${tips[$index]}" "$snapshot_tip"; then
      parent_cleanup_failure "$control" "$slug parent target snapshot differs from safe exact authority"
      return 1
    fi
    epoch_target_tips+=("$snapshot_tip")
    snapshot_count=$((snapshot_count + 1))
  done < "$target_snapshot"
  snapshot_lines="$(wc -l < "$target_snapshot" | tr -d ' ')"
  if [[ "$snapshot_count" -ne "$row_count" ]] || [[ "$snapshot_count" -ne "$snapshot_lines" ]]; then
    parent_cleanup_failure "$control" "$slug parent target snapshot row count is malformed"
    return 1
  fi
  target_snapshot_hash="$(file_hash "$target_snapshot")"

  intent="$control/parent-cleanup-intent"
  intent_value="prepared\t$manifest_hash\t$target_snapshot_hash"
  if [[ -e "$intent" || -L "$intent" ]]; then
    [[ "$(read_task_value "$intent" 2>/dev/null || true)" == "$intent_value" ]] || {
      parent_cleanup_failure "$control" "$slug parent cleanup intent differs from exact authority"
      return 1
    }
  else
    write_task_value "$intent" "$intent_value" || {
      parent_cleanup_failure "$control" "$slug parent cleanup intent publication failed"
      return 1
    }
  fi
  append_cleanup_journal "$control/parent-cleanup-journal.log" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ') parent cleanup prepared: $manifest_hash ${tips[0]}" || {
    parent_cleanup_failure "$control" "$slug parent cleanup journal preparation failed"
    return 1
  }
  archive_parent_artifacts "$mission_dir" "$control" "$slug" "$mission_version" || {
    parent_cleanup_failure "$control" "$slug required parent archive artifacts are missing, unsafe, or changed"
    return 1
  }

  for ((index=0; index < row_count; index++)); do
    worktree="${worktrees[$index]}"
    branch="${branches[$index]}"
    parent_tip="${tips[$index]}"
    repo="${repos[$index]}"
    target="${targets[$index]}"
    snapshot_tip="${epoch_target_tips[$index]}"
    local_tip="${local_tips[$index]}"
    remote_tip="${remote_tips[$index]}"
    if [[ -d "$worktree" ]]; then
      parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
        "$target_snapshot" "$target_snapshot_hash" "$repo" "$target" "$parent_tip" "$snapshot_tip" || {
        parent_cleanup_failure "$control" "$slug parent or target authority changed before settings deletion"
        return 1
      }
      remove_planted_settings "$slug" "$worktree" || {
        parent_cleanup_failure "$control" "$slug planted worker settings could not be removed safely"
        return 1
      }
      parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
        "$target_snapshot" "$target_snapshot_hash" "$repo" "$target" "$parent_tip" "$snapshot_tip" || {
        parent_cleanup_failure "$control" "$slug parent or target authority changed before worktree deletion"
        return 1
      }
      git -C "$repo" worktree remove "$worktree" >/dev/null 2>&1 || {
        parent_cleanup_failure "$control" "$slug exact parent worktree removal failed"
        return 1
      }
      echo "  removed parent worktree"
    fi
    if [[ -n "$local_tip" ]]; then
      parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
        "$target_snapshot" "$target_snapshot_hash" "$repo" "$target" "$parent_tip" "$snapshot_tip" || {
        parent_cleanup_failure "$control" "$slug parent or target authority changed before local ref deletion"
        return 1
      }
      git -C "$repo" update-ref -d "refs/heads/$branch" "$parent_tip" >/dev/null 2>&1 || {
        parent_cleanup_failure "$control" "$slug exact parent local branch removal failed"
        return 1
      }
      echo "  deleted parent local branch"
    fi
    if [[ "$remote_tip" != absent ]]; then
      parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
        "$target_snapshot" "$target_snapshot_hash" "$repo" "$target" "$parent_tip" "$snapshot_tip" || {
        parent_cleanup_failure "$control" "$slug parent or target authority changed before remote ref deletion"
        return 1
      }
      git -C "$repo" push --force-with-lease="refs/heads/$branch:$parent_tip" \
        origin ":refs/heads/$branch" >/dev/null 2>&1 || {
        parent_cleanup_failure "$control" "$slug exact parent remote branch removal failed"
        return 1
      }
      [[ "$(child_remote_branch_tip "$repo" "$branch")" == absent ]] || {
        parent_cleanup_failure "$control" "$slug parent remote branch removal could not be verified"
        return 1
      }
      echo "  deleted parent remote branch"
    fi
    parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
      "$target_snapshot" "$target_snapshot_hash" "$repo" "$target" "$parent_tip" "$snapshot_tip" || {
      parent_cleanup_failure "$control" "$slug parent or target authority changed before worktree parent pruning"
      return 1
    }
    rmdir "$(dirname "$worktree")" 2>/dev/null || true
  done
  for ((index=0; index < row_count; index++)); do
    parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
      "$target_snapshot" "$target_snapshot_hash" "${repos[$index]}" "${targets[$index]}" \
      "${tips[$index]}" "${epoch_target_tips[$index]}" || {
      parent_cleanup_failure "$control" "$slug parent or target authority changed before completion publication"
      return 1
    }
  done
  append_cleanup_journal "$control/parent-cleanup-journal.log" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ') parent cleanup collected: $manifest_hash ${tips[0]}" || {
    parent_cleanup_failure "$control" "$slug parent cleanup completion journal failed"
    return 1
  }
  archive_replace_regular "$control/parent-cleanup-journal.log" "$archive_dir/cleanup-journal.log" || {
    parent_cleanup_failure "$control" "$slug cleanup journal could not be preserved in the archive"
    return 1
  }
  for ((index=0; index < row_count; index++)); do
    parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
      "$target_snapshot" "$target_snapshot_hash" "${repos[$index]}" "${targets[$index]}" \
      "${tips[$index]}" "${epoch_target_tips[$index]}" || {
      parent_cleanup_failure "$control" "$slug parent or target authority changed before cleanup intent removal"
      return 1
    }
  done
  remove_regular_authority "$intent" || {
    parent_cleanup_failure "$control" "$slug completed parent cleanup intent could not be removed"
    return 1
  }
  for ((index=0; index < row_count; index++)); do
    parent_target_epoch_matches "$control" "$manifest" "$manifest_hash" \
      "$target_snapshot" "$target_snapshot_hash" "${repos[$index]}" "${targets[$index]}" \
      "${tips[$index]}" "${epoch_target_tips[$index]}" || {
      parent_cleanup_failure "$control" "$slug parent or target authority changed before target snapshot removal"
      return 1
    }
  done
  remove_regular_authority "$target_snapshot" || {
    parent_cleanup_failure "$control" "$slug completed parent target snapshot could not be removed"
    return 1
  }
  for ((index=0; index < row_count; index++)); do
    parent_target_ref_matches "${repos[$index]}" "${targets[$index]}" \
      "${tips[$index]}" "${epoch_target_tips[$index]}" || {
      parent_cleanup_failure "$control" "$slug target authority changed before collected-state publication"
      return 1
    }
  done
  write_task_value "$control/parent-cleanup-state" collected || {
    parent_cleanup_failure "$control" "$slug parent collected state publication failed"
    return 1
  }
}

legacy_worktree_is_clean_or_planted() {
  local slug="$1" worktree="$2" status settings stamp expected actual
  status="$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
  [[ -z "$status" ]] && return 0
  [[ "$status" == "?? .claude/settings.local.json" ]] || return 1
  settings="$worktree/.claude/settings.local.json"
  stamp="$HUB/control/$slug/worker-settings.sha256"
  [[ -f "$settings" && ! -L "$settings" && -f "$stamp" && ! -L "$stamp" ]] || return 1
  expected="$(read_task_value "$stamp" 2>/dev/null || true)"
  actual="$(file_hash "$settings")"
  [[ -n "$expected" && "$expected" == "$actual" ]]
}

legacy_manifest_epoch_matches() {
  local slug="$1" mission_state_file="$2" manifest="$3" manifest_hash="$4"
  local worktree="$5" branch="$6" base="$7" repo="$8"
  local expected_worktree="$9" expected_local="${10}" expected_remote="${11}"
  local repo_phys repo_common registered=0 worktree_phys worktree_common actual_branch
  local actual_tip local_tip remote_tip state

  [[ -f "$mission_state_file" && ! -L "$mission_state_file" ]] || return 1
  state="$(read_task_value "$mission_state_file" 2>/dev/null || true)"
  is_completed_state "$state" || return 1
  [[ -f "$manifest" && ! -L "$manifest" && "$(file_hash "$manifest")" == "$manifest_hash" ]] || return 1
  [[ -d "$repo" && ! -L "$repo" ]] || return 1
  repo_phys="$(cd "$repo" && pwd -P 2>/dev/null || true)"
  [[ -n "$repo_phys" && "$repo_phys" == "$repo" ]] || return 1
  repo_common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
  [[ -n "$repo_common" ]] || return 1
  [[ "$branch" == "orc/$slug" ]] || return 1
  [[ "$(git -C "$repo" check-ref-format --normalize "refs/heads/$branch" 2>/dev/null || true)" == "refs/heads/$branch" ]] || return 1
  case "$base" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [[ "$(git -C "$repo" rev-parse --verify "${base}^{commit}" 2>/dev/null || true)" == "$base" ]] || return 1

  git -C "$repo" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $worktree" && registered=1
  case "$expected_worktree" in
    present)
      [[ -d "$worktree" && ! -L "$worktree" && "$registered" -eq 1 ]] || return 1
      worktree_phys="$(cd "$worktree" && pwd -P 2>/dev/null || true)"
      [[ -n "$worktree_phys" && "$worktree_phys" == "$worktree" ]] || return 1
      worktree_common="$(cd "$worktree" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
      [[ "$worktree_common" == "$repo_common" ]] || return 1
      actual_branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      actual_tip="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
      [[ "$actual_branch" == "$branch" && "$actual_tip" == "$base" ]] || return 1
      legacy_worktree_is_clean_or_planted "$slug" "$worktree" || return 1
      ;;
    absent)
      [[ "$registered" -eq 0 && ! -e "$worktree" && ! -L "$worktree" ]] || return 1
      ;;
    *) return 1 ;;
  esac

  local_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)"
  case "$expected_local" in
    present) [[ "$local_tip" == "$base" ]] || return 1 ;;
    absent) [[ -z "$local_tip" ]] || return 1 ;;
    *) return 1 ;;
  esac
  remote_tip="$(child_remote_branch_tip "$repo" "$branch")"
  [[ "$remote_tip" != error ]] || return 1
  case "$expected_remote" in
    present) [[ "$remote_tip" == "$base" ]] || return 1 ;;
    absent) [[ "$remote_tip" == absent ]] || return 1 ;;
    *) return 1 ;;
  esac
}

clean_manifest_row() {
  local slug="$1" mission_state_file="$2" manifest="$3" manifest_hash="$4"
  local worktree="$5" branch="$6" base="$7" repo="$8"
  local expected_branch="orc/$slug" repo_phys repo_common worktree_common worktree_state
  local registered=0 local_tip remote_tip local_state remote_state

  [[ "$branch" == "$expected_branch" ]] || {
    problem "$slug legacy manifest branch is outside its exact mission namespace"
    return 1
  }
  if [[ -z "$repo" || (! -e "$repo" && ! -L "$repo") ]]; then
    # Cross-device hubs legitimately contain absolute repo paths from another
    # machine. They are not actionable here and must not block local cleanup.
    return 0
  fi
  [[ -d "$repo" && ! -L "$repo" ]] || {
    problem "$slug legacy manifest repository path is unsafe"
    return 1
  }
  repo_phys="$(cd "$repo" && pwd -P 2>/dev/null || true)"
  [[ -n "$repo_phys" && "$repo_phys" == "$repo" ]] || {
    problem "$slug legacy manifest repository path is not exact and canonical"
    return 1
  }
  repo_common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
  [[ -n "$repo_common" ]] || {
    problem "$slug legacy manifest repository is not Git"
    return 1
  }
  [[ "$(git -C "$repo" check-ref-format --normalize "refs/heads/$branch" 2>/dev/null || true)" == "refs/heads/$branch" ]] || {
    problem "$slug legacy manifest branch is invalid"
    return 1
  }
  case "$base" in ''|*[!0-9a-fA-F]*)
    problem "$slug legacy manifest base SHA is invalid"
    return 1
    ;;
  esac
  [[ "$(git -C "$repo" rev-parse --verify "${base}^{commit}" 2>/dev/null || true)" == "$base" ]] || {
    problem "$slug legacy manifest base SHA does not resolve exactly"
    return 1
  }

  git -C "$repo" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $worktree" && registered=1
  if [[ -d "$worktree" && ! -L "$worktree" ]]; then
    [[ "$registered" -eq 1 && "$(cd "$worktree" && pwd -P 2>/dev/null || true)" == "$worktree" ]] || {
      problem "$slug legacy worktree path or registration is not exact"
      return 1
    }
    worktree_common="$(cd "$worktree" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P 2>/dev/null || true)"
    [[ "$worktree_common" == "$repo_common" && \
      "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$branch" && \
      "$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" == "$base" ]] || {
      problem "$slug legacy worktree identity or tip differs from exact authority"
      return 1
    }
    legacy_worktree_is_clean_or_planted "$slug" "$worktree" || {
      problem "$worktree has uncommitted or untracked files"
      return 1
    }
    worktree_state=present
    note "stale worktree ($slug): $worktree"
  elif [[ "$registered" -eq 1 || -e "$worktree" || -L "$worktree" ]]; then
    problem "$slug legacy worktree path is unsafe or missing while registered"
    return 1
  else
    worktree_state=absent
  fi

  local_tip="$(git -C "$repo" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)"
  if [[ -n "$local_tip" ]]; then
    [[ "$local_tip" == "$base" ]] || {
      problem "$slug legacy local branch tip changed"
      return 1
    }
    local_state=present
    note "stale local branch ($slug): $branch in $repo"
  else
    local_state=absent
  fi
  remote_tip="$(child_remote_branch_tip "$repo" "$branch")"
  if [[ "$remote_tip" == error ]]; then
    problem "$slug legacy remote-state check failed; exact resources preserved"
    return 1
  elif [[ "$remote_tip" != absent ]]; then
    [[ "$remote_tip" == "$base" ]] || {
      problem "$slug legacy remote branch tip changed; exact resources preserved"
      return 1
    }
    remote_state=present
    note "stale remote branch ($slug): $branch on origin"
  else
    remote_state=absent
  fi

  legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
    "$worktree" "$branch" "$base" "$repo" "$worktree_state" "$local_state" "$remote_state" || {
    problem "$slug legacy cleanup authority changed after validation; exact resources preserved"
    return 1
  }
  [[ "$CLEAN" -eq 1 ]] || return 0

  if [[ "$worktree_state" == present ]]; then
    legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
      "$worktree" "$branch" "$base" "$repo" present "$local_state" "$remote_state" || {
      problem "$slug legacy cleanup authority changed before worktree deletion"
      return 1
    }
    remove_planted_settings "$slug" "$worktree" || return 1
    legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
      "$worktree" "$branch" "$base" "$repo" present "$local_state" "$remote_state" || {
      problem "$slug legacy cleanup authority changed after local settings removal"
      return 1
    }
    git -C "$repo" worktree remove "$worktree" >/dev/null 2>&1 || {
      problem "git refused to remove exact worktree $worktree"
      return 1
    }
    worktree_state=absent
    echo "  removed worktree"
  fi

  if [[ "$local_state" == present ]]; then
    legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
      "$worktree" "$branch" "$base" "$repo" "$worktree_state" present "$remote_state" || {
      problem "$slug legacy cleanup authority changed before local branch deletion"
      return 1
    }
    git -C "$repo" update-ref -d "refs/heads/$branch" "$base" >/dev/null 2>&1 || {
      problem "could not delete exact local branch $branch"
      return 1
    }
    local_state=absent
    echo "  deleted local branch"
  fi

  if [[ "$remote_state" == present ]]; then
    legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
      "$worktree" "$branch" "$base" "$repo" "$worktree_state" "$local_state" present || {
      problem "$slug legacy cleanup authority changed before remote branch deletion"
      return 1
    }
    git -C "$repo" push --force-with-lease="refs/heads/$branch:$base" \
      origin ":refs/heads/$branch" >/dev/null 2>&1 || {
      problem "could not delete exact remote branch origin/$branch"
      return 1
    }
    remote_state=absent
    [[ "$(child_remote_branch_tip "$repo" "$branch")" == absent ]] || {
      problem "$slug legacy remote branch deletion could not be verified"
      return 1
    }
    echo "  deleted remote branch"
  fi

  legacy_manifest_epoch_matches "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
    "$worktree" "$branch" "$base" "$repo" "$worktree_state" "$local_state" "$remote_state" || {
    problem "$slug legacy cleanup authority changed after exact deletion"
    return 1
  }
  [[ "$worktree_state" == absent ]] && rmdir "$(dirname "$worktree")" 2>/dev/null || true
}

scan_legacy_manifest_rows() {
  local slug="$1" mission_state_file="$2" manifest="$3" manifest_hash="$4"
  local worktree branch base repo extra row_count=0 row_safe=1
  while IFS=$'\t' read -r worktree branch base repo extra || [[ -n "${worktree:-}" ]]; do
    row_count=$((row_count + 1))
    if [[ -z "${worktree:-}" || -z "${branch:-}" || -z "${base:-}" || \
      -z "${repo:-}" || -n "${extra:-}" ]]; then
      problem "$slug legacy worktree manifest is malformed"
      row_safe=0
      continue
    fi
    clean_manifest_row "$slug" "$mission_state_file" "$manifest" "$manifest_hash" \
      "$worktree" "$branch" "$base" "$repo" || row_safe=0
  done < "$manifest"
  if [[ "$row_count" -eq 0 || "$row_count" -ne "$(wc -l < "$manifest" | tr -d ' ')" ]]; then
    problem "$slug legacy worktree manifest has blank, unterminated, or malformed rows"
    row_safe=0
  fi
  [[ "$row_safe" -eq 1 ]]
}

scan_root() {
  local root="$1" root_phys mission mission_phys slug state manifest manifest_hash
  local requested_clean control control_phys control_root_phys lock_held legacy_safe
  [[ -d "$root" && ! -L "$root" ]] || return 0
  root_phys="$(cd "$root" && pwd -P 2>/dev/null || true)"
  [[ -n "$root_phys" ]] || return 0
  for mission in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [[ -e "$mission" || -L "$mission" ]] || continue
    slug="$(basename "$mission")"
    [[ -z "$MISSION_FILTER" || "$slug" == "$MISSION_FILTER" ]] || continue
    if ! gc_valid_lock_token "$slug" || [[ ! -d "$mission" || -L "$mission" ]]; then
      problem "$root contains an unsafe mission entry: $slug"
      continue
    fi
    mission_phys="$(cd "$mission" && pwd -P 2>/dev/null || true)"
    if [[ -z "$mission_phys" || "$(dirname "$mission_phys")" != "$root_phys" || \
      "$(basename "$mission_phys")" != "$slug" || "$mission_phys" != "$mission" ]]; then
      problem "$root mission entry is not an exact direct physical child: $slug"
      continue
    fi
    if [[ -e "$HUB/control/$slug/parent-cleanup-manifest.txt" || \
      -L "$HUB/control/$slug/parent-cleanup-manifest.txt" ]]; then
      continue
    fi
    [[ -f "$mission/state" && ! -L "$mission/state" ]] || continue
    state="$(read_task_value "$mission/state" 2>/dev/null || true)"
    is_completed_state "$state" || continue
    manifest="$mission/worktrees.txt"
    [[ -f "$manifest" && ! -L "$manifest" ]] || continue
    manifest_hash="$(file_hash "$manifest")"
    requested_clean="$CLEAN"
    lock_held=0
    control="$HUB/control/$slug"
    if [[ "$requested_clean" -eq 1 && (-e "$control" || -L "$control") ]]; then
      [[ -d "$control" && ! -L "$control" ]] || {
        problem "$slug legacy coordinator control entry is unsafe"
        continue
      }
      control_root_phys="$(cd "$HUB/control" && pwd -P 2>/dev/null || true)"
      control_phys="$(cd "$control" && pwd -P 2>/dev/null || true)"
      if [[ -z "$control_root_phys" || -z "$control_phys" || "$control_phys" != "$control" || \
        "$(dirname "$control_phys")" != "$control_root_phys" || "$(basename "$control_phys")" != "$slug" ]]; then
        problem "$slug legacy coordinator control entry is not exact and canonical"
        continue
      fi
      if ! gc_acquire_lifecycle_lock "$control_phys"; then
        problem "$slug legacy coordinator lifecycle mutation lock is unsafe or busy"
        gc_release_lifecycle_lock >/dev/null 2>&1 || true
        continue
      fi
      lock_held=1
    fi
    legacy_safe=1
    if [[ "$requested_clean" -eq 1 ]]; then
      CLEAN=0
      if ! scan_legacy_manifest_rows "$slug" "$mission/state" "$manifest" "$manifest_hash"; then
        legacy_safe=0
      fi
      CLEAN=1
    fi
    if [[ "$legacy_safe" -eq 1 ]]; then
      scan_legacy_manifest_rows "$slug" "$mission/state" "$manifest" "$manifest_hash" || true
    fi
    CLEAN="$requested_clean"
    if [[ "$lock_held" -eq 1 ]] && ! gc_release_lifecycle_lock; then
      problem "$slug legacy coordinator lifecycle mutation lock release failed"
    fi
  done
}

scan_exact_parent_root() {
  local root="$1" root_phys mission mission_phys slug control_phys lock_held lock_reason
  [[ -d "$root" && ! -L "$root" ]] || return 0
  root_phys="$(cd "$root" && pwd -P 2>/dev/null || true)"
  [[ -n "$root_phys" ]] || return 0
  for mission in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [[ -e "$mission" || -L "$mission" ]] || continue
    slug="$(basename "$mission")"
    [[ -z "$MISSION_FILTER" || "$slug" == "$MISSION_FILTER" ]] || continue
    if ! gc_valid_lock_token "$slug" || [[ ! -d "$mission" || -L "$mission" ]]; then
      problem "$root contains an unsafe mission entry: $slug"
      continue
    fi
    mission_phys="$(cd "$mission" && pwd -P 2>/dev/null || true)"
    if [[ -z "$mission_phys" || "$(dirname "$mission_phys")" != "$root_phys" || \
      "$(basename "$mission_phys")" != "$slug" || "$mission_phys" != "$mission" ]]; then
      problem "$root mission entry is not an exact direct physical child: $slug"
      continue
    fi
    [[ -f "$mission/state" && ! -L "$mission/state" ]] || continue
    lock_held=0
    if [[ "$CLEAN" -eq 1 && -d "$HUB/control/$slug" && ! -L "$HUB/control/$slug" ]]; then
      control_phys="$(cd "$HUB/control/$slug" && pwd -P)"
      if ! gc_acquire_lifecycle_lock "$control_phys"; then
        lock_reason="$slug coordinator lifecycle mutation lock is unsafe or busy during parent GC"
        problem "$lock_reason"
        gc_release_lifecycle_lock >/dev/null 2>&1 || true
        record_parent_lock_pending "$mission" "$slug" "$control_phys" "$lock_reason" >/dev/null 2>&1 || true
        continue
      fi
      lock_held=1
    fi
    clean_exact_parent_mission "$mission" "$slug" || true
    if [[ "$lock_held" -eq 1 ]] && ! gc_release_lifecycle_lock; then
      problem "$slug coordinator lifecycle mutation lock release failed after parent GC"
    fi
  done
}

scan_child_tasks() {
  local control_root="$HUB/control" control_root_phys mission_dir mission_phys
  local mission task_root task_root_phys task_dir task_phys task_id control_phys lock_held
  [[ -d "$control_root" && ! -L "$control_root" ]] || return 0
  control_root_phys="$(cd "$control_root" && pwd -P 2>/dev/null || true)"
  [[ -n "$control_root_phys" ]] || return 0
  for mission_dir in "$control_root"/* "$control_root"/.[!.]* "$control_root"/..?*; do
    [[ -e "$mission_dir" || -L "$mission_dir" ]] || continue
    mission="$(basename "$mission_dir")"
    [[ -z "$MISSION_FILTER" || "$mission" == "$MISSION_FILTER" ]] || continue
    if ! gc_valid_lock_token "$mission" || [[ ! -d "$mission_dir" || -L "$mission_dir" ]]; then
      problem "$mission coordinator control entry is unsafe"
      continue
    fi
    mission_phys="$(cd "$mission_dir" && pwd -P 2>/dev/null || true)"
    if [[ -z "$mission_phys" || "$(dirname "$mission_phys")" != "$control_root_phys" || \
      "$(basename "$mission_phys")" != "$mission" || "$mission_phys" != "$mission_dir" ]]; then
      problem "$mission coordinator control entry is not an exact direct physical child"
      continue
    fi
    task_root="$mission_dir/tasks"
    if [[ ! -e "$task_root" && ! -L "$task_root" ]]; then
      continue
    fi
    if [[ ! -d "$task_root" || -L "$task_root" ]]; then
      problem "$mission coordinator task registry is unsafe"
      continue
    fi
    task_root_phys="$(cd "$task_root" && pwd -P 2>/dev/null || true)"
    if [[ -z "$task_root_phys" || "$(dirname "$task_root_phys")" != "$mission_phys" || \
      "$(basename "$task_root_phys")" != tasks ]]; then
      problem "$mission coordinator task registry is not an exact direct physical child"
      continue
    fi
    lock_held=0
    if [[ "$CLEAN" -eq 1 ]]; then
      control_phys="$(cd "$mission_dir" && pwd -P)"
      if ! gc_acquire_lifecycle_lock "$control_phys"; then
        problem "$mission coordinator lifecycle mutation lock is unsafe or busy"
        gc_release_lifecycle_lock >/dev/null 2>&1 || true
        continue
      fi
      lock_held=1
    fi
    for task_dir in "$task_root"/* "$task_root"/.[!.]* "$task_root"/..?*; do
      [[ -e "$task_dir" || -L "$task_dir" ]] || continue
      task_id="$(basename "$task_dir")"
      if ! gc_valid_lock_token "$task_id" || [[ ! -d "$task_dir" || -L "$task_dir" ]]; then
        problem "$mission/$task_id coordinator task entry is unsafe"
        continue
      fi
      task_phys="$(cd "$task_dir" && pwd -P 2>/dev/null || true)"
      if [[ -z "$task_phys" || "$(dirname "$task_phys")" != "$task_root_phys" || \
        "$(basename "$task_phys")" != "$task_id" || "$task_phys" != "$task_dir" ]]; then
        problem "$mission/$task_id coordinator task entry is not an exact direct physical child"
        continue
      fi
      clean_child_task "$mission" "$task_id" "$task_dir" || true
    done
    if [[ "$lock_held" -eq 1 ]] && ! gc_release_lifecycle_lock; then
      problem "$mission coordinator lifecycle mutation lock release failed"
    fi
  done
}

scan_child_tasks
scan_exact_parent_root "$HUB/missions"
scan_exact_parent_root "$HUB/archive"
scan_root "$HUB/archive"
scan_root "$HUB/missions"

if [[ "$FOUND" -eq 0 && "$ERRORS" -eq 0 ]]; then
  echo "gc: nothing stale"
elif [[ "$CLEAN" -eq 0 ]]; then
  if [[ -n "$MISSION_FILTER" ]]; then
    echo "gc: rerun with --mission $MISSION_FILTER --clean to remove the above"
  else
    echo "gc: use --mission <slug> --clean to collect one exact mission"
  fi
fi

if [[ "$ERRORS" -gt 0 ]]; then
  echo "gc: $ERRORS cleanup check(s) failed; affected branches were preserved" >&2
  if [[ "$CLEAN" -eq 1 ]]; then
    exit 1
  fi
  echo "gc: report-only discovery completed with preserved cleanup warnings" >&2
fi
