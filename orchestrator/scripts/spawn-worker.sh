#!/usr/bin/env bash
# Spawn (or resume) one stage of an orchestrator mission's staged pipeline.
#
#   spawn-worker.sh --mission-dir <dir> --control-dir <dir>
#       --worktree <primary> [--worktree <other>]...
#       fresh PLAN stage: claude (Fable-5) reads brief.md, plans, exits state=planned
#   spawn-worker.sh ... --resume "<message>" [--stage plan|review]
#       [--quota-fallback]
#       resumes the same Fable session for clarification, plan revision,
#       independent review, re-review, or crash salvage.
#
# The FIRST --worktree is the primary session cwd and holds the guard/gate hooks
# in `.claude/settings.local.json`.
# The orchestrator launches this via Bash with run_in_background:true and is woken
# when the process exits. On exit (any state) a macOS notification fires as the
# user-facing backup. Stdout ALWAYS carries either the stage summary or a
# diagnostic — never empty.

set -euo pipefail

MISSION_DIR="" CONTROL_DIR="" RESUME_MSG="" STAGE="" QUOTA_FALLBACK=0
WORKTREES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --control-dir) CONTROL_DIR="$2"; shift 2 ;;
    --worktree)    WORKTREES+=("$2"); shift 2 ;;
    --resume)      RESUME_MSG="$2"; shift 2 ;;
    --stage)       STAGE="$2"; shift 2 ;;
    --quota-fallback) QUOTA_FALLBACK=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$MISSION_DIR" || -z "$CONTROL_DIR" || "${#WORKTREES[@]}" -eq 0 ]]; then
  echo "usage: --mission-dir <dir> --control-dir <dir> --worktree <primary> [--worktree <other>]... [--stage plan|review] [--resume <msg>] [--quota-fallback]" >&2
  exit 1
fi
case "$STAGE" in
  ''|plan|review) ;;
  *) echo "invalid --stage: $STAGE (plan|review)" >&2; exit 1 ;;
esac
PRIMARY="${WORKTREES[0]}"
PLAN_STAGE="${STAGE:-plan}"
PLAN_MODEL="${ORC_PLAN_MODEL:-claude-fable-5}"
case "$PLAN_MODEL" in
  claude-fable-5|claude-opus-5) ;;
  *) echo "unsupported planning model: $PLAN_MODEL" >&2; exit 1 ;;
esac
for WT in "${WORKTREES[@]}"; do
  if [[ ! -d "$WT" ]]; then
    if [[ "$WT" == "$PRIMARY" ]]; then
      echo "primary worktree not found: $WT" >&2
    else
      echo "worktree not found: $WT" >&2
    fi
    exit 1
  fi
done

[[ -d "$MISSION_DIR" && ! -L "$MISSION_DIR" ]] || { echo "mission directory missing or symlinked: $MISSION_DIR" >&2; exit 1; }
[[ -d "$CONTROL_DIR" && ! -L "$CONTROL_DIR" ]] || { echo "coordinator control directory missing or symlinked: $CONTROL_DIR" >&2; exit 1; }

read_planning_session_authority() {
  local authority="$CONTROL_DIR/planning-session-id" value
  [[ -s "$authority" && ! -L "$authority" ]] || {
    echo "planning session authority is missing or unsafe" >&2
    return 1
  }
  value="$(tr -d '\n' < "$authority")"
  [[ "$(wc -l < "$authority" | tr -d ' ')" == 1 && -n "$value" ]] || {
    echo "planning session authority is malformed" >&2
    return 1
  }
  case "$value" in
    *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*)
      echo "planning session authority is malformed" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

publish_planning_session_authority() {
  local authority="$CONTROL_DIR/planning-session-id" temporary candidate
  if [[ -e "$authority" || -L "$authority" ]]; then
    read_planning_session_authority
    return
  fi
  candidate="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  temporary="$(mktemp "$CONTROL_DIR/.planning-session-id.XXXXXX")" || return 1
  printf '%s\n' "$candidate" > "$temporary"
  chmod 0600 "$temporary"
  if ! ln "$temporary" "$authority" 2>/dev/null; then
    rm -f -- "$temporary"
    read_planning_session_authority
    return
  fi
  [[ "$temporary" -ef "$authority" ]] || {
    rm -f -- "$temporary"
    echo "planning session authority ownership mismatch" >&2
    return 1
  }
  python3 - "$authority" "$CONTROL_DIR" <<'PY'
import os
import sys
for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
  rm -f -- "$temporary"
  printf '%s\n' "$candidate"
}

publish_quota_fallback_receipt() {
  local session_id="$1" receipt="$CONTROL_DIR/quota-fallback-$PLAN_STAGE.json" temporary
  [[ "$PLAN_MODEL" == claude-opus-5 ]] || {
    echo "--quota-fallback requires claude-opus-5" >&2
    return 1
  }
  [[ -n "$RESUME_MSG" ]] || {
    echo "Opus fallback already consumed; a second fresh session is forbidden" >&2
    return 1
  }
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    [[ -f "$receipt" && ! -L "$receipt" ]] || {
      echo "quota fallback receipt is unsafe" >&2
      return 1
    }
    jq -e --arg stage "$PLAN_STAGE" --arg session "$session_id" \
      'keys == ["from","session_id","stage","to"] and .from == "claude-fable-5" and .to == "claude-opus-5" and .stage == $stage and .session_id == $session' \
      "$receipt" >/dev/null || {
        echo "quota fallback receipt conflicts with this stage" >&2
        return 1
      }
    return 0
  fi
  temporary="$(mktemp "$CONTROL_DIR/.quota-fallback-$PLAN_STAGE.XXXXXX")" || return 1
  jq -cS -n --arg stage "$PLAN_STAGE" --arg session "$session_id" \
    '{from:"claude-fable-5",session_id:$session,stage:$stage,to:"claude-opus-5"}' > "$temporary"
  chmod 0600 "$temporary"
  if ! ln "$temporary" "$receipt" 2>/dev/null; then
    rm -f -- "$temporary"
    echo "quota fallback receipt publication raced" >&2
    return 1
  fi
  [[ "$temporary" -ef "$receipt" ]] || {
    rm -f -- "$temporary"
    echo "quota fallback receipt ownership mismatch" >&2
    return 1
  }
  python3 - "$receipt" "$CONTROL_DIR" <<'PY'
import os
import sys
for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
  rm -f -- "$temporary"
}

if [[ "$PLAN_MODEL" == claude-opus-5 ]]; then
  [[ "$QUOTA_FALLBACK" -eq 1 ]] || {
    echo "claude-opus-5 requires --quota-fallback" >&2
    exit 1
  }
  [[ -n "$RESUME_MSG" ]] || {
    echo "Opus fallback already consumed; a second fresh session is forbidden" >&2
    exit 1
  }
elif [[ "$QUOTA_FALLBACK" -eq 1 ]]; then
  echo "--quota-fallback is invalid for claude-fable-5" >&2
  exit 1
fi

CONTROL_MANIFEST="$CONTROL_DIR/worktrees.txt"
[[ -s "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" ]] || { echo "coordinator control manifest missing, empty, or symlinked: $CONTROL_MANIFEST" >&2; exit 1; }
cmp -s "$CONTROL_MANIFEST" "$MISSION_DIR/worktrees.txt" || { echo "worker manifest does not match coordinator control manifest" >&2; exit 1; }
[[ ! "$CONTROL_MANIFEST" -ef "$MISSION_DIR/worktrees.txt" ]] || { echo "worker manifest must be a copy, not a hard link to coordinator authority" >&2; exit 1; }

MISSION_PHYS="$(cd "$MISSION_DIR" && pwd -P)"
CONTROL_PHYS="$(cd "$CONTROL_DIR" && pwd -P)"
case "$CONTROL_PHYS" in
  "$MISSION_PHYS"|"$MISSION_PHYS"/*) echo "control directory must be outside the worker-writable mission directory" >&2; exit 1 ;;
esac
CONTROL_WORKTREES=()
while IFS=$'\t' read -r WT BRANCH BASE REPO EXTRA || [[ -n "${WT:-}" ]]; do
  [[ -n "$WT" && -n "$BRANCH" && -n "$BASE" && -n "$REPO" && -z "${EXTRA:-}" ]] || { echo "malformed coordinator control manifest" >&2; exit 1; }
  CONTROL_WORKTREES+=("$WT")
done < "$CONTROL_MANIFEST"
[[ "${#CONTROL_WORKTREES[@]}" -eq "${#WORKTREES[@]}" ]] || { echo "launcher worktrees do not match coordinator control manifest" >&2; exit 1; }
for I in "${!WORKTREES[@]}"; do
  ARG_PHYS="$(cd "${WORKTREES[$I]}" && pwd -P)"
  MANIFEST_PHYS="$(cd "${CONTROL_WORKTREES[$I]}" && pwd -P)"
  [[ "$ARG_PHYS" == "$MANIFEST_PHYS" ]] || { echo "launcher worktrees do not match coordinator control manifest" >&2; exit 1; }
  case "$CONTROL_PHYS" in
    "$ARG_PHYS"|"$ARG_PHYS"/*) echo "control directory must be outside worker-writable worktrees" >&2; exit 1 ;;
  esac
done

# The Claude planning route uses Fable-5 high, with one receipt-backed Opus-5
# fallback for the exact stage. Native implementation is launched separately.
FABLE_TOOLS=(Read Glob Grep Write Edit Skill)
FABLE_TOOL_LIST="$(IFS=,; echo "${FABLE_TOOLS[*]}")"
WORKER_FLAGS=(--model "$PLAN_MODEL" --effort high --permission-mode dontAsk --tools "$FABLE_TOOL_LIST" --allowedTools "$FABLE_TOOL_LIST" --output-format json)
WORKER_FLAGS+=(--add-dir "$MISSION_DIR" --add-dir "$CONTROL_DIR")
for ((i = 1; i < ${#WORKTREES[@]}; i++)); do
  WORKER_FLAGS+=(--add-dir "${WORKTREES[$i]}")
done

# Make the 10x-engineer pipeline available even if ambient config lacks it.
TENX="$(ls -d "$HOME"/.claude/plugins/cache/*/10x-engineer/*/ 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$TENX" ]]; then
  WORKER_FLAGS+=(--plugin-dir "${TENX%/}")
fi

notify() {
  local STATE SLUG
  STATE="$(cat "$MISSION_DIR/state" 2>/dev/null || echo unknown)"
  SLUG="$(basename "$MISSION_DIR")"
  # Sanitize before AppleScript string interpolation: strip backslashes and
  # double quotes, collapse newlines.
  STATE="${STATE//\\/}"; STATE="${STATE//\"/}"; STATE="${STATE//$'\n'/ }"
  SLUG="${SLUG//\\/}";   SLUG="${SLUG//\"/}";   SLUG="${SLUG//$'\n'/ }"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"state: $STATE\" with title \"Orchestrator: $SLUG\"" >/dev/null 2>&1 || true
  fi
}
trap notify EXIT

# Next output file: max existing numeric suffix + 1, so gaps never clobber
# or mis-order (a plain count would reuse an index after deletions).
next_output() {
  local MAX=0 F N
  for F in "$MISSION_DIR"/worker-output-*.json; do
    if [[ ! -e "$F" ]]; then
      continue
    fi
    N="${F##*worker-output-}"
    N="${N%.json}"
    case "$N" in
      ''|*[!0-9]*) ;;
      *)
        N="$((10#$N))"
        if [[ "$N" -gt "$MAX" ]]; then
          MAX="$N"
        fi
        ;;
    esac
  done
  echo "$MISSION_DIR/worker-output-$((MAX + 1)).json"
}

SESSION_FILE="$MISSION_DIR/session.txt"
STATE_FILE="$MISSION_DIR/state"
RC=0

fsync_paths() {
  python3 - "$@" <<'PY'
import os
import sys
for path in sys.argv[1:]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

verify_pending_state() {
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || {
    echo "mission state is missing or unsafe" >&2
    return 1
  }
  [[ "$(cat "$STATE_FILE")" == pending ]] || {
    echo "fresh planning launch requires pending mission state" >&2
    return 1
  }
}

publish_running_state() {
  local temporary
  verify_pending_state || return 1
  temporary="$(mktemp "$MISSION_DIR/.state.XXXXXX")" || return 1
  printf 'running\n' > "$temporary"
  chmod 0600 "$temporary"
  fsync_paths "$temporary"
  mv -f -- "$temporary" "$STATE_FILE"
  fsync_paths "$STATE_FILE" "$MISSION_DIR"
}

verify_approved_contract() {
  local APPROVED
  for APPROVED in approved-design.md approved-plan.md brief-exec.md; do
    [[ -s "$CONTROL_DIR/$APPROVED" && ! -L "$CONTROL_DIR/$APPROVED" ]] || { echo "approved control artifact missing, empty, or symlinked: $CONTROL_DIR/$APPROVED" >&2; return 1; }
  done
  [[ -s "$CONTROL_DIR/approved.sha256" && ! -L "$CONTROL_DIR/approved.sha256" ]] || { echo "approved hash manifest missing, empty, or symlinked: $CONTROL_DIR/approved.sha256" >&2; return 1; }
  (cd "$CONTROL_DIR" && shasum -a 256 -c approved.sha256 >/dev/null) || { echo "approved control artifact hash mismatch" >&2; return 1; }
}

verify_worker_settings() {
  local SETTINGS STAMP EXPECTED ACTUAL
  SETTINGS="$PRIMARY/.claude/settings.local.json"
  STAMP="$CONTROL_DIR/worker-settings.sha256"
  [[ -s "$SETTINGS" && ! -L "$SETTINGS" ]] || {
    echo "worker settings missing, empty, or symlinked: $SETTINGS" >&2
    return 1
  }
  [[ -s "$STAMP" && ! -L "$STAMP" ]] || {
    echo "coordinator worker settings hash missing, empty, or symlinked: $STAMP" >&2
    return 1
  }
  EXPECTED="$(tr -d '\n\r' < "$STAMP")"
  if [[ "${#EXPECTED}" -ne 64 ]]; then
    echo "invalid coordinator worker settings hash" >&2
    return 1
  fi
  case "$EXPECTED" in
    *[!0-9a-f]*) echo "invalid coordinator worker settings hash" >&2; return 1 ;;
  esac
  ACTUAL="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  [[ "$ACTUAL" == "$EXPECTED" ]] || {
    echo "worker settings hash mismatch: $SETTINGS" >&2
    return 1
  }
}

# P1-1 (2026-08-08 retrospective): a worker killed by a usage/session limit
# exits nonzero with state stuck in running — surface it as a structured,
# retryable outcome (exit 75) instead of a crash.
detect_quota() { # <files...> — returns 0 and prints the hint line if matched
  local HINT
  HINT="$(grep -hoiE "(you've (hit|reached) your [a-z0-9 -]+ limit|session limit|usage limit|rate limit|usage-credits)[^\"]{0,80}" "$@" 2>/dev/null | head -1 || true)"
  if [[ -n "$HINT" ]]; then
    echo "QUOTA_LIMIT detected — retry_hint: $HINT"
    return 0
  fi
  return 1
}

# ------------------------------------------------------- plan/review (claude)
verify_worker_settings || exit 1
if [[ "$STAGE" == "review" ]]; then
  verify_approved_contract || exit 1
fi
if [[ -z "$RESUME_MSG" ]]; then
  if [[ ! -f "$MISSION_DIR/brief.md" ]]; then
    echo "no brief.md in $MISSION_DIR" >&2
    exit 1
  fi
  verify_pending_state || exit 1
  SESSION_ID="$(publish_planning_session_authority)" || exit 1
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A fresh spawn over an existing session file keeps the old ids traceable.
  HISTORY=""
  if [[ -f "$SESSION_FILE" ]]; then
    HISTORY="$(grep '^superseded: ' "$SESSION_FILE" 2>/dev/null || true)"
    OLD_ID="$(awk -F': ' '/^session_id:/ {print $2}' "$SESSION_FILE")"
    if [[ -n "$OLD_ID" && "$OLD_ID" != "$SESSION_ID" ]]; then
      if [[ -n "$HISTORY" ]]; then
        HISTORY="$HISTORY
superseded: $OLD_ID $NOW"
      else
        HISTORY="superseded: $OLD_ID $NOW"
      fi
    fi
  fi
  SESSION_TEMP="$(mktemp "$MISSION_DIR/.session.XXXXXX")" || exit 1
  {
    if [[ -n "$HISTORY" ]]; then
      printf '%s\n' "$HISTORY"
    fi
    echo "session_id: $SESSION_ID"
    echo "backend: claude-headless"
    echo "model: $PLAN_MODEL"
    echo "spawned: $NOW"
    echo "stage: plan"
    echo "spawn_pid: $$"
  } > "$SESSION_TEMP"
  chmod 0600 "$SESSION_TEMP"
  fsync_paths "$SESSION_TEMP"
  mv -f -- "$SESSION_TEMP" "$SESSION_FILE"
  fsync_paths "$SESSION_FILE" "$MISSION_DIR"
  if [[ "${ORC_SPAWN_TEST_FAIL_AFTER_AUTHORITY:-0}" == 1 ]]; then
    echo "injected failure after planning authority publication" >&2
    exit 70
  fi
  publish_running_state || exit 1
  OUT="$(next_output)"
  cd "$PRIMARY"
  # Brief goes in on stdin — passing it as an argv word risks ARG_MAX.
  ORC_WORKER=1 claude -p --session-id "$SESSION_ID" "${WORKER_FLAGS[@]}" \
    < "$MISSION_DIR/brief.md" \
    > "$OUT" 2>> "$MISSION_DIR/worker-stderr.log" || RC=$?
else
  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "no session.txt to resume in $MISSION_DIR" >&2
    exit 1
  fi
  SESSION_ID="$(awk -F': ' '/^session_id:/ {id=$2} END {print id}' "$SESSION_FILE")"
  if [[ -z "$SESSION_ID" ]]; then
    echo "no session_id in $SESSION_FILE" >&2
    exit 1
  fi
  CONTROL_SESSION_ID="$(read_planning_session_authority)" || exit 1
  if [[ "$SESSION_ID" != "$CONTROL_SESSION_ID" ]]; then
    echo "planning session authority mismatch" >&2
    exit 1
  fi
  if [[ "$PLAN_MODEL" == claude-opus-5 ]]; then
    publish_quota_fallback_receipt "$SESSION_ID" || exit 1
  fi
  {
    echo "resumed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$STAGE" == "review" ]]; then
      echo "stage: review"
    fi
    echo "spawn_pid: $$"
  } >> "$SESSION_FILE"
  OUT="$(next_output)"
  cd "$PRIMARY"
  ORC_WORKER=1 claude -p --resume "$SESSION_ID" "$RESUME_MSG" \
    "${WORKER_FLAGS[@]}" \
    > "$OUT" 2>> "$MISSION_DIR/worker-stderr.log" || RC=$?
fi

# Surface the mission session's final text + exit metadata on stdout for the
# orchestrator's wake-up — ALWAYS, even when claude exited nonzero.
if [[ "$RC" -ne 0 ]] && detect_quota "$OUT" "$MISSION_DIR/worker-stderr.log"; then
  exit 75
fi
SUMMARY="" SUMMARY_OK=1
if [[ -s "$OUT" ]]; then
  if SUMMARY="$(jq -er '"mission turn ended · is_error=\(.is_error) · turns=\(.num_turns)\n---\n\(.result)"' "$OUT" 2>/dev/null)"; then
    SUMMARY_OK=0
  fi
fi
if [[ "$SUMMARY_OK" -eq 0 ]]; then
  printf '%s\n' "$SUMMARY"
  exit "$RC"
fi
echo "mission session produced no parseable JSON output (claude exit=$RC) — last stderr lines:"
tail -n 20 "$MISSION_DIR/worker-stderr.log" 2>/dev/null || true
if [[ "$RC" -eq 0 ]]; then
  RC=1
fi
exit "$RC"
