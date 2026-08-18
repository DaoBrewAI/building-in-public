#!/usr/bin/env bash
# Garbage collector for completed orchestrator missions.
#
#   orchestrator-gc.sh --hub <hub dir> [--clean]
#
# Default is report-only. --clean removes exact orc/* worktree and branch rows
# recorded by completed missions, including the matching origin branch. A
# mission is collectible only when state is accepted/done/complete(d), whether
# it is under archive/ or awaiting archival under missions/.

set -uo pipefail

HUB=""
CLEAN=0
FOUND=0
ERRORS=0

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

note() {
  FOUND=1
  echo "$1"
}

problem() {
  ERRORS=$((ERRORS + 1))
  echo "  refused: $1" >&2
}

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
