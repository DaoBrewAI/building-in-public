#!/usr/bin/env bash
# Garbage collector for orchestrator leftovers (P2 of the 2026-08-08
# retrospective): archived missions whose worktrees, branches, or .worktrees/
# directories were never cleaned up.
#
#   orchestrator-gc.sh --hub <hub dir> [--clean]
#
# Default = report only. --clean removes what the report lists:
#   git worktree remove --force + git branch -D + rm -rf of the empty umbrella
#   .worktrees/<slug>/ dirs. Only missions found under $HUB/archive/ are
#   touched — anything under $HUB/missions/ is live and never GC'd.

set -uo pipefail

HUB="" CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub)   HUB="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$HUB" || ! -d "$HUB" ]]; then
  echo "usage: orchestrator-gc.sh --hub <hub dir> [--clean]" >&2
  exit 1
fi
UMBRELLA="$(cd "$HUB/.." && pwd)"
FOUND=0

note() { FOUND=1; echo "$1"; }

for M in "$HUB"/archive/*/; do
  [[ -d "$M" ]] || continue
  SLUG="$(basename "$M")"
  MANIFEST="$M/worktrees.txt"
  [[ -f "$MANIFEST" ]] || continue
  while IFS=$'\t' read -r WT BRANCH BASE REPO || [[ -n "${WT:-}" ]]; do
    [[ -z "${WT:-}" ]] && continue
    if [[ -d "$WT" ]]; then
      note "stale worktree ($SLUG): $WT"
      if [[ "$CLEAN" -eq 1 ]]; then
        git -C "$REPO" worktree remove --force "$WT" 2>/dev/null \
          || rm -rf "$WT"
        echo "  removed"
      fi
    fi
    if [[ -n "${REPO:-}" && -d "$REPO" ]] && git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
      # Only branches matching the orc/<slug> convention are GC candidates.
      case "$BRANCH" in
        orc/*)
          note "stale branch ($SLUG): $BRANCH in $REPO"
          if [[ "$CLEAN" -eq 1 ]]; then
            git -C "$REPO" worktree prune 2>/dev/null || true
            git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 && echo "  deleted" || echo "  could not delete (checked out somewhere?)"
          fi
          ;;
      esac
    fi
  done < "$MANIFEST"
done

# Umbrella .worktrees/<slug>/ dirs whose mission is archived (or unknown).
if [[ -d "$UMBRELLA/.worktrees" ]]; then
  for D in "$UMBRELLA/.worktrees"/*/; do
    [[ -d "$D" ]] || continue
    SLUG="$(basename "$D")"
    if [[ -d "$HUB/missions/$SLUG" ]]; then
      continue   # live mission — never touch
    fi
    note "orphan .worktrees dir: $D"
    if [[ "$CLEAN" -eq 1 ]]; then
      # Deregister any worktrees inside it first, then drop the directory.
      for WT in "$D"*/; do
        [[ -d "$WT" ]] || continue
        GITFILE="$WT/.git"
        if [[ -f "$GITFILE" ]]; then
          MAINREPO="$(sed -n 's|^gitdir: \(.*\)/\.git/worktrees/.*|\1|p' "$GITFILE")"
          if [[ -n "$MAINREPO" && -d "$MAINREPO" ]]; then
            git -C "$MAINREPO" worktree remove --force "$WT" 2>/dev/null || true
          fi
        fi
      done
      rm -rf "$D"
      echo "  removed"
    fi
  done
fi

if [[ "$FOUND" -eq 0 ]]; then
  echo "gc: nothing stale"
elif [[ "$CLEAN" -eq 0 ]]; then
  echo "gc: rerun with --clean to remove the above"
fi
