#!/usr/bin/env bash
# Trusted commit broker for a completed sandboxed Codex mission.
# Codex workspace-write intentionally cannot mutate linked-worktree Git metadata,
# so this wrapper validates the worker diff before creating mission commits.
set -euo pipefail

MISSION_DIR="" CONTROL_MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --control-manifest) CONTROL_MANIFEST="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$MISSION_DIR" && -n "$CONTROL_MANIFEST" ]] || {
  echo "usage: --mission-dir <dir> --control-manifest <file>" >&2
  exit 1
}
WORKER_MANIFEST="$MISSION_DIR/worktrees.txt"
[[ -s "$CONTROL_MANIFEST" && -f "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" ]] || {
  echo "missing, empty, or symlinked coordinator control manifest: $CONTROL_MANIFEST" >&2
  exit 1
}
[[ -s "$WORKER_MANIFEST" ]] || { echo "missing or empty worker manifest: $WORKER_MANIFEST" >&2; exit 1; }
[[ ! "$CONTROL_MANIFEST" -ef "$WORKER_MANIFEST" ]] || {
  echo "worker manifest must be a copy, not a hard link to coordinator authority" >&2
  exit 1
}

MISSION_PHYS="$(cd "$MISSION_DIR" && pwd -P)"
CONTROL_DIR_PHYS="$(cd "$(dirname "$CONTROL_MANIFEST")" && pwd -P)"
CONTROL_PHYS="$CONTROL_DIR_PHYS/$(basename "$CONTROL_MANIFEST")"
case "$CONTROL_PHYS" in
  "$MISSION_PHYS"/*) echo "control manifest must be outside the worker-writable mission directory" >&2; exit 1 ;;
esac
cmp -s "$CONTROL_MANIFEST" "$WORKER_MANIFEST" || {
  echo "worker manifest does not match coordinator control manifest" >&2
  exit 1
}

WORKTREES=() BRANCHES=() BASES=() REPOS=()
while IFS=$'\t' read -r WT BRANCH BASE REPO EXTRA || [[ -n "${WT:-}" ]]; do
  [[ -n "$WT" && -n "$BRANCH" && -n "$BASE" && -n "$REPO" && -z "${EXTRA:-}" ]] || {
    echo "malformed worktrees manifest row" >&2
    exit 1
  }
  WORKTREES+=("$WT"); BRANCHES+=("$BRANCH"); BASES+=("$BASE"); REPOS+=("$REPO")
done < "$CONTROL_MANIFEST"

is_protected() {
  case "$1" in
    AGENTS.md|*/AGENTS.md|.codex/*|*/.codex/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Preflight every repository before making the first commit.
for I in "${!WORKTREES[@]}"; do
  WT="${WORKTREES[$I]}"; BRANCH="${BRANCHES[$I]}"; BASE="${BASES[$I]}"
  [[ -d "$WT" ]] || { echo "worktree not found: $WT" >&2; exit 1; }
  ROOT="$(git -C "$WT" rev-parse --show-toplevel)"
  WT_PHYS="$(cd "$WT" && pwd -P)"
  ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
  [[ "$ROOT_PHYS" == "$WT_PHYS" ]] || { echo "manifest worktree is not its git root: $WT" >&2; exit 1; }
  case "$CONTROL_PHYS" in
    "$WT_PHYS"/*) echo "control manifest must be outside worker-writable worktrees" >&2; exit 1 ;;
  esac
  [[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]] || {
    echo "branch mismatch in $WT (expected $BRANCH)" >&2
    exit 1
  }
  git -C "$WT" cat-file -e "$BASE^{commit}"
  git -C "$WT" merge-base --is-ancestor "$BASE" HEAD || {
    echo "base $BASE is not an ancestor of $BRANCH" >&2
    exit 1
  }

  while IFS= read -r -d '' PATHNAME; do
    if is_protected "$PATHNAME"; then
      echo "protected path changed in $WT: $PATHNAME" >&2
      exit 1
    fi
  done < <({
    git -C "$WT" diff --name-only -z HEAD
    git -C "$WT" ls-files --others --exclude-standard -z -- \
      AGENTS.md ':(glob)**/AGENTS.md' .codex ':(glob)**/.codex/**'
    git -C "$WT" ls-files --others --ignored --exclude-standard -z -- \
      AGENTS.md ':(glob)**/AGENTS.md' .codex ':(glob)**/.codex/**'
  })
done

TMP="$MISSION_DIR/commits.txt.tmp.$$"
: > "$TMP"
SLUG="$(basename "$MISSION_DIR")"
for I in "${!WORKTREES[@]}"; do
  WT="${WORKTREES[$I]}"; BRANCH="${BRANCHES[$I]}"; BASE="${BASES[$I]}"; REPO="${REPOS[$I]}"
  git -C "$WT" add -A
  if ! git -C "$WT" diff --cached --quiet; then
    git -C "$WT" -c commit.gpgsign=false commit -m "orchestrator: complete $SLUG" >/dev/null
    echo "committed $BRANCH in $WT"
  elif [[ "$(git -C "$WT" rev-list --count "$BASE"..HEAD)" -eq 0 ]]; then
    echo "no mission changes to commit on $BRANCH in $WT" >&2
    rm -f "$TMP"
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$BRANCH" "$(git -C "$WT" rev-parse HEAD)" "$REPO" >> "$TMP"
done
mv "$TMP" "$MISSION_DIR/commits.txt"
