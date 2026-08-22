#!/usr/bin/env bash
# Garbage collector for completed orchestrator missions.
#
#   orchestrator-gc.sh --hub <hub dir> [--clean]
#
# Default is report-only. --clean removes exact manifest-recorded parent and
# integrated orc-task/* child resources. Remote deletion is attempted only
# after a successful exact remote-state check. Unsafe and nonterminal resources
# are preserved; transient child failures become retriable cleanup_pending.

set -uo pipefail

HUB=""
CLEAN=0
FOUND=0
ERRORS=0
GC_LOCK_FILE=""
GC_LOCK_CANDIDATE=""
GC_LOCK_OWNED=0
GC_LOCK_CANDIDATE_OWNED=0
GC_LOCK_PUBLISH_INTENT=0

usage() {
  echo "usage: orchestrator-gc.sh --hub <hub dir> [--clean]" >&2
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
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$HUB" || ! -d "$HUB" ]]; then
  usage
  exit 1
fi
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

gc_pid_is_live() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'
}

gc_release_lifecycle_lock() {
  local ok=1
  if [[ "$GC_LOCK_PUBLISH_INTENT" -eq 1 ]]; then
    if [[ -f "$GC_LOCK_FILE" && ! -L "$GC_LOCK_FILE" && \
      -f "$GC_LOCK_CANDIDATE" && ! -L "$GC_LOCK_CANDIDATE" && \
      "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]]; then
      rm -f -- "$GC_LOCK_FILE" || ok=0
      GC_LOCK_OWNED=0
      GC_LOCK_PUBLISH_INTENT=0
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
  [[ "$ok" -eq 1 ]]
}

gc_acquire_lifecycle_lock() {
  local control="$1" token stale_pid stale_token stale_extra stale_candidate
  local candidate_pid candidate_token candidate_extra
  GC_LOCK_FILE="$control/.task-worktree.lock"
  token="$RANDOM.$(date +%s)"
  GC_LOCK_CANDIDATE="$GC_LOCK_FILE.$$.$token"
  [[ ! -e "$GC_LOCK_CANDIDATE" && ! -L "$GC_LOCK_CANDIDATE" ]] || return 1
  (umask 077 && printf '%s\t%s\n' "$$" "$token" > "$GC_LOCK_CANDIDATE") || return 1
  GC_LOCK_CANDIDATE_OWNED=1
  GC_LOCK_PUBLISH_INTENT=1
  if ln "$GC_LOCK_CANDIDATE" "$GC_LOCK_FILE" 2>/dev/null; then
    [[ "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]] || return 1
    GC_LOCK_OWNED=1
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
  rm -f -- "$GC_LOCK_FILE" "$stale_candidate" || return 1
  GC_LOCK_PUBLISH_INTENT=1
  ln "$GC_LOCK_CANDIDATE" "$GC_LOCK_FILE" 2>/dev/null || return 1
  [[ "$GC_LOCK_FILE" -ef "$GC_LOCK_CANDIDATE" ]] || return 1
  GC_LOCK_OWNED=1
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

clean_manifest_row() {
  local slug="$1" worktree="$2" branch="$3" repo="$4"
  local row_safe=1 remote_state

  case "$branch" in
    orc/*) ;;
    *) return 0 ;;
  esac
  if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
    # Cross-device hubs legitimately contain absolute repo paths from another
    # machine. They are not actionable here and must not block local cleanup.
    return 0
  fi

  if [[ -d "$worktree" ]]; then
    note "stale worktree ($slug): $worktree"
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    note "stale local branch ($slug): $branch in $repo"
  fi
  remote_state="$(remote_branch_state "$repo" "$branch")"
  if [[ "$remote_state" == present ]]; then
    note "stale remote branch ($slug): $branch on origin"
  elif [[ "$remote_state" == error ]]; then
    ERRORS=$((ERRORS + 1))
    row_safe=0
  fi

  [[ "$CLEAN" -eq 1 ]] || return 0
  [[ "$row_safe" -eq 1 ]] || return 1

  if [[ -d "$worktree" ]]; then
    remove_planted_settings "$slug" "$worktree" || row_safe=0
    if [[ "$row_safe" -eq 1 ]] && [[ -n "$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
      problem "$worktree has uncommitted or untracked files"
      row_safe=0
    fi
    if [[ "$row_safe" -eq 1 ]]; then
      if git -C "$repo" worktree remove "$worktree" >/dev/null 2>&1; then
        echo "  removed worktree"
      else
        problem "git refused to remove worktree $worktree"
        row_safe=0
      fi
    fi
  fi

  if [[ "$row_safe" -eq 1 ]] && git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    if git -C "$repo" branch -D "$branch" >/dev/null 2>&1; then
      echo "  deleted local branch"
    else
      problem "could not delete local branch $branch (it may be checked out elsewhere)"
      row_safe=0
    fi
  fi

  if [[ "$row_safe" -eq 1 && "$remote_state" == present ]]; then
    if git -C "$repo" push origin --delete "$branch" >/dev/null 2>&1; then
      echo "  deleted remote branch"
    else
      problem "could not delete remote branch origin/$branch"
      row_safe=0
    fi
  fi

  if [[ "$row_safe" -eq 1 ]]; then
    rmdir "$(dirname "$worktree")" 2>/dev/null || true
  fi
  [[ "$row_safe" -eq 1 ]]
}

scan_root() {
  local root="$1" mission slug state manifest worktree branch base repo
  [[ -d "$root" ]] || return 0
  for mission in "$root"/*/; do
    [[ -d "$mission" ]] || continue
    slug="$(basename "$mission")"
    [[ -f "$mission/state" ]] || continue
    state="$(tr -d '[:space:]' < "$mission/state")"
    is_completed_state "$state" || continue
    manifest="$mission/worktrees.txt"
    [[ -f "$manifest" ]] || continue
    while IFS=$'\t' read -r worktree branch base repo || [[ -n "${worktree:-}" ]]; do
      [[ -n "${worktree:-}" && -n "${branch:-}" && -n "${repo:-}" ]] || continue
      clean_manifest_row "$slug" "$worktree" "$branch" "$repo" || true
    done < "$manifest"
  done
}

scan_child_tasks() {
  local control_root="$HUB/control" mission_dir mission task_dir task_id control_phys lock_held
  [[ -d "$control_root" ]] || return 0
  for mission_dir in "$control_root"/*/; do
    [[ -d "$mission_dir" && ! -L "$mission_dir" ]] || continue
    mission="$(basename "$mission_dir")"
    [[ -d "$mission_dir/tasks" && ! -L "$mission_dir/tasks" ]] || continue
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
    for task_dir in "$mission_dir/tasks"/*/; do
      [[ -d "$task_dir" && ! -L "$task_dir" ]] || continue
      task_id="$(basename "$task_dir")"
      clean_child_task "$mission" "$task_id" "$task_dir" || true
    done
    if [[ "$lock_held" -eq 1 ]] && ! gc_release_lifecycle_lock; then
      problem "$mission coordinator lifecycle mutation lock release failed"
    fi
  done
}

scan_child_tasks
scan_root "$HUB/archive"
scan_root "$HUB/missions"

if [[ "$FOUND" -eq 0 && "$ERRORS" -eq 0 ]]; then
  echo "gc: nothing stale"
elif [[ "$CLEAN" -eq 0 ]]; then
  echo "gc: rerun with --clean to remove the above"
fi

if [[ "$ERRORS" -gt 0 ]]; then
  echo "gc: $ERRORS cleanup check(s) failed; affected branches were preserved" >&2
  exit 1
fi
