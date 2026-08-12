#!/usr/bin/env bash
# Commit broker for the codex exec stage (P0-1 of the 2026-08-08 retrospective).
#
# The codex workspace-write sandbox keeps the ACTIVE git database semantically
# read-only (verified on codex-cli 0.147.0: renamed gitdirs, standalone
# conversion, and extra writable roots all fail) — the executor can never
# commit. Instead of a BLOCKED round-trip per task, the executor writes
#   $MISSION_DIR/COMMIT-REQUEST-<n>.json   {"worktree": "<abs>", "paths": ["rel"...], "message": "..."}
# and polls (without ending its turn) for
#   $MISSION_DIR/COMMIT-DONE-<n>.json      {"hash": "...", "branch": "..."}
#   $MISSION_DIR/COMMIT-REJECTED-<n>.json  {"reason": "..."}
#
# spawn-worker.sh runs this loop alongside the codex process and kills it when
# the exec turn ends. --once processes the current backlog and exits (tests).
#
#   commit-broker.sh --mission-dir <dir> --control-dir <dir> [--once] [--interval <seconds>]
#
# Validation per request (any failure -> REJECTED, never a partial commit):
#   - worker-facing worktrees.txt still matches the coordinator-owned copy
#   - worktree is one registered in $CONTROL_DIR/worktrees.txt
#   - paths are relative, contain no "..", and resolve inside the worktree
#   - no path is .claude/settings.json (the planted hooks)
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

reject() { # <n> <reason>
  jq -n --arg reason "$2" '{reason: $reason}' > "$MISSION_DIR/COMMIT-REJECTED-$1.json"
  echo "$(date -u +%FT%TZ) REJECTED $1: $2"
}

process_request() { # <request file>
  local REQ="$1" N WT MSG REGISTERED_WT REGISTERED_BRANCH
  N="${REQ##*COMMIT-REQUEST-}"; N="${N%.json}"
  # Already answered -> skip (executor may retry with a new n after REJECTED).
  if [[ -e "$MISSION_DIR/COMMIT-DONE-$N.json" || -e "$MISSION_DIR/COMMIT-REJECTED-$N.json" ]]; then
    return 0
  fi

  if ! cmp -s "$MANIFEST" "$WORKER_MANIFEST"; then
    reject "$N" "worker manifest does not match coordinator control manifest"
    return 0
  fi

  if ! jq -e . "$REQ" >/dev/null 2>&1; then
    # Possibly caught mid-write; leave it alone until it is a few seconds old.
    local AGE
    AGE="$(( $(date +%s) - $(stat -f %m "$REQ" 2>/dev/null || echo 0) ))"
    if [[ "$AGE" -lt 5 ]]; then return 0; fi
    reject "$N" "COMMIT-REQUEST-$N.json is not valid JSON"
    return 0
  fi
  WT="$(jq -r '.worktree // empty' "$REQ")"
  MSG="$(jq -r '.message // empty' "$REQ")"
  local NPATHS
  NPATHS="$(jq -r '.paths | length' "$REQ" 2>/dev/null || echo 0)"
  if [[ -z "$WT" || -z "$MSG" || "$NPATHS" -eq 0 ]]; then
    reject "$N" "request must carry worktree, non-empty paths[], and message"
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
  while IFS=$'\t' read -r MANIFEST_WT MANIFEST_BRANCH MANIFEST_BASE MANIFEST_REPO EXTRA || [[ -n "${MANIFEST_WT:-}" ]]; do
    [[ -n "$MANIFEST_WT" && -n "$MANIFEST_BRANCH" && -n "$MANIFEST_BASE" && -n "$MANIFEST_REPO" && -z "${EXTRA:-}" ]] || continue
    [[ -d "$MANIFEST_WT" ]] || continue
    MANIFEST_PHYS="$(cd "$MANIFEST_WT" && pwd -P)"
    if [[ "$WT" == "$MANIFEST_PHYS" ]]; then
      REGISTERED_WT="$MANIFEST_PHYS"
      REGISTERED_BRANCH="$MANIFEST_BRANCH"
      break
    fi
  done < "$MANIFEST"
  if [[ -z "$REGISTERED_WT" ]]; then
    reject "$N" "worktree not registered in coordinator control manifest: $WT"
    return 0
  fi
  CURRENT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$CURRENT_BRANCH" != "$REGISTERED_BRANCH" ]]; then
    reject "$N" "worktree branch mismatch: expected $REGISTERED_BRANCH, found ${CURRENT_BRANCH:-unknown}"
    return 0
  fi

  local P
  while IFS= read -r P; do
    case "$P" in
      /*)                       reject "$N" "absolute path in manifest: $P (use worktree-relative paths)"; return 0 ;;
      *"/../"*|"../"*|*"/.."|"..") reject "$N" "path escapes the worktree: $P"; return 0 ;;
      ".claude/settings.json")  reject "$N" "refusing to commit the planted .claude/settings.json"; return 0 ;;
    esac
    if [[ ! -e "$WT/$P" && -z "$(git -C "$WT" status --porcelain -- "$P" 2>/dev/null)" ]]; then
      reject "$N" "path has no changes and does not exist: $P"
      return 0
    fi
  done < <(jq -r '.paths[]' "$REQ")

  # No modifications outside the requested paths: dirty ⊆ manifest.
  local DIRTY EXTRA=""
  DIRTY="$(git -C "$WT" status --porcelain 2>/dev/null | cut -c4- | sed 's/^"\(.*\)"$/\1/')"
  while IFS= read -r P; do
    [[ -z "$P" ]] && continue
    if ! jq -e --arg p "$P" '.paths | index($p)' "$REQ" >/dev/null; then
      EXTRA="${EXTRA}${P} "
    fi
  done <<< "$DIRTY"
  if [[ -n "$EXTRA" ]]; then
    reject "$N" "worktree has changes outside the request: ${EXTRA}— include them or split into another request"
    return 0
  fi

  local OUT HASH BRANCH
  if ! OUT="$(cd "$WT" && jq -r '.paths[]' "$REQ" | tr '\n' '\0' | xargs -0 git add -- 2>&1)"; then
    reject "$N" "git add failed: $OUT"
    return 0
  fi
  if ! OUT="$(git -C "$WT" commit -m "$MSG" 2>&1)"; then
    git -C "$WT" reset -q HEAD -- . 2>/dev/null || true
    reject "$N" "git commit failed: $OUT"
    return 0
  fi
  HASH="$(git -C "$WT" rev-parse HEAD)"
  BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  jq -n --arg hash "$HASH" --arg branch "$BRANCH" '{hash: $hash, branch: $branch}' \
    > "$MISSION_DIR/COMMIT-DONE-$N.json"
  echo "$(date -u +%FT%TZ) DONE $N: $HASH on $BRANCH"
}

while :; do
  for REQ in "$MISSION_DIR"/COMMIT-REQUEST-*.json; do
    [[ -e "$REQ" ]] || continue
    process_request "$REQ"
  done
  if [[ "$ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
