#!/usr/bin/env bash
# Provision preflight (P0-2/P0-3 of the 2026-08-08 retrospective). Run by the
# orchestrator at the END of Phase 2, before spawning the plan stage.
#
#   provision-preflight.sh --mission-dir <dir> --worktree <primary> [--worktree <other>]...
#
# The native Codex child sandbox has no network and a read-only HOME, so everything the
# executor needs must exist in the worktrees beforehand; and the ONLY trustworthy
# baseline is one taken OUTSIDE the sandbox. Per worktree:
#   1. deps        — package-lock.json -> npm ci; Package.swift -> swift package resolve
#   2. swift caches— .swift-caches/{clang,swiftpm-cache,swiftpm-config,module-cache}
#                    created inside the worktree + added to the worktree's git exclude
#   3. baseline    — auto-detected full test run OUTSIDE any sandbox; results land in
#                    $MISSION_DIR/baseline-attestation.json
#
# Exit 0 = everything green. Exit 3 = one or more baselines red — the orchestrator
# must adjudicate (record the accepted-failure-set in DECISIONS.md and the exec
# brief's {{ACCEPTED_FAILURES}}) before spawning. Other nonzero = setup failure.

set -uo pipefail

MISSION_DIR=""
WORKTREES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --worktree)    WORKTREES+=("$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$MISSION_DIR" || "${#WORKTREES[@]}" -eq 0 ]]; then
  echo "usage: provision-preflight.sh --mission-dir <dir> --worktree <primary> [--worktree <other>]..." >&2
  exit 1
fi

ATTEST="$MISSION_DIR/baseline-attestation.json"
RESULTS="[]"
BASELINE_RED=0

append_result() { # <json object>
  RESULTS="$(jq -c --argjson r "$1" '. + [$r]' <<< "$RESULTS")"
}

for WT in "${WORKTREES[@]}"; do
  if [[ ! -d "$WT" ]]; then
    echo "worktree not found: $WT" >&2
    exit 1
  fi
  STEPS="[]"
  step() { # <label> <exit code>
    STEPS="$(jq -c --arg l "$1" --argjson c "$2" '. + [{step: $l, exit: $c}]' <<< "$STEPS")"
  }

  echo "== preflight: $WT"

  # 1. Dependencies
  if [[ -f "$WT/package-lock.json" ]]; then
    (cd "$WT" && npm ci --no-audit --no-fund) > "$MISSION_DIR/preflight-npm.log" 2>&1
    RCX=$?; step "npm ci" "$RCX"
    if [[ "$RCX" -ne 0 ]]; then echo "npm ci FAILED (see preflight-npm.log)"; fi
  fi
  if [[ -f "$WT/Package.swift" ]]; then
    (cd "$WT" && swift package resolve) > "$MISSION_DIR/preflight-swift-resolve.log" 2>&1
    RCX=$?; step "swift package resolve" "$RCX"
    if [[ "$RCX" -ne 0 ]]; then echo "swift package resolve FAILED (see preflight-swift-resolve.log)"; fi

    # 2. In-worktree caches the sandbox can write to (HOME is read-only there)
    mkdir -p "$WT/.swift-caches/clang" "$WT/.swift-caches/swiftpm-cache" \
             "$WT/.swift-caches/swiftpm-config" "$WT/.swift-caches/module-cache"
    EXCL="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null)"
    if [[ -n "$EXCL" ]]; then
      mkdir -p "$(dirname "$EXCL")"
      grep -qxF '.swift-caches/' "$EXCL" 2>/dev/null || echo '.swift-caches/' >> "$EXCL"
    fi
    step "swift caches" 0
  fi

  # 3. Baseline OUTSIDE any sandbox — the attested truth the executor compares against
  BCMD=""
  if [[ -f "$WT/package.json" ]] && jq -e '.scripts.test' "$WT/package.json" >/dev/null 2>&1; then
    BCMD="npm test"
  elif [[ -f "$WT/Package.swift" ]]; then
    BCMD="swift test"
  fi
  BEXIT=null BTAIL=""
  if [[ -n "$BCMD" ]]; then
    BLOG="$MISSION_DIR/preflight-baseline-$(basename "$WT").log"
    (cd "$WT" && eval "$BCMD") > "$BLOG" 2>&1
    BEXIT=$?
    BTAIL="$(tail -n 25 "$BLOG")"
    if [[ "$BEXIT" -ne 0 ]]; then
      BASELINE_RED=1
      echo "baseline RED: $BCMD (exit $BEXIT) — see $(basename "$BLOG")"
    else
      echo "baseline green: $BCMD"
    fi
  else
    echo "no baseline command detected (no npm test script / Package.swift)"
  fi

  append_result "$(jq -nc --arg wt "$WT" --arg cmd "$BCMD" --argjson steps "$STEPS" \
    --argjson exit "$BEXIT" --arg tail "$BTAIL" \
    '{worktree: $wt, steps: $steps, baseline: {command: $cmd, exit: $exit, tail: $tail}}')"
done

jq -n --argjson results "$RESULTS" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{attested: $date, results: $results}' > "$ATTEST"
echo "attestation written: $ATTEST"

if [[ "$BASELINE_RED" -eq 1 ]]; then
  echo "PREFLIGHT: baseline red — adjudicate before spawning (accepted-failure-set -> DECISIONS.md + exec brief)"
  exit 3
fi
echo "PREFLIGHT: all green"
