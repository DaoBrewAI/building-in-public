#!/usr/bin/env bash
# Spawn (or resume) the autonomous headless session for one orchestrator mission.
#
#   spawn-worker.sh --mission-dir <hub mission dir> --worktree <primary> [--worktree <other>]...
#   spawn-worker.sh --mission-dir <dir> --worktree <primary> [...] --resume "<message>"
#
# The FIRST --worktree is the primary: it is the session cwd and holds the
# guard/gate hooks in its .claude/settings.json. The orchestrator launches this
# via Bash with run_in_background:true and is woken when the process exits.
# On exit (any state) a macOS notification fires as the user-facing backup.
# Stdout ALWAYS carries either the mission summary or a diagnostic — never empty.

set -euo pipefail

MISSION_DIR="" RESUME_MSG=""
WORKTREES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --worktree)    WORKTREES+=("$2"); shift 2 ;;
    --resume)      RESUME_MSG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$MISSION_DIR" || "${#WORKTREES[@]}" -eq 0 ]]; then
  echo "usage: --mission-dir <dir> --worktree <primary> [--worktree <other>]... [--resume <msg>]" >&2
  exit 1
fi
PRIMARY="${WORKTREES[0]}"
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

# Mission spec is fixed by the orchestrator plugin: Opus 4.8, extra-high effort,
# permissions skipped (the hooks in the primary worktree's settings are the fence).
WORKER_FLAGS=(--model claude-opus-4-8 --effort xhigh --dangerously-skip-permissions --output-format json)

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
RC=0

if [[ -z "$RESUME_MSG" ]]; then
  if [[ ! -f "$MISSION_DIR/brief.md" ]]; then
    echo "no brief.md in $MISSION_DIR" >&2
    exit 1
  fi
  SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A fresh spawn over an existing session file keeps the old ids traceable.
  HISTORY=""
  if [[ -f "$SESSION_FILE" ]]; then
    HISTORY="$(grep '^superseded: ' "$SESSION_FILE" 2>/dev/null || true)"
    OLD_ID="$(awk -F': ' '/^session_id:/ {print $2}' "$SESSION_FILE")"
    if [[ -n "$OLD_ID" ]]; then
      if [[ -n "$HISTORY" ]]; then
        HISTORY="$HISTORY
superseded: $OLD_ID $NOW"
      else
        HISTORY="superseded: $OLD_ID $NOW"
      fi
    fi
  fi
  {
    if [[ -n "$HISTORY" ]]; then
      printf '%s\n' "$HISTORY"
    fi
    echo "session_id: $SESSION_ID"
    echo "backend: claude-headless"
    echo "spawned: $NOW"
  } > "$SESSION_FILE"
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
  SESSION_ID="$(awk -F': ' '/^session_id:/ {print $2}' "$SESSION_FILE")"
  if [[ -z "$SESSION_ID" ]]; then
    echo "no session_id in $SESSION_FILE" >&2
    exit 1
  fi
  echo "resumed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_FILE"
  OUT="$(next_output)"
  cd "$PRIMARY"
  ORC_WORKER=1 claude -p --resume "$SESSION_ID" "$RESUME_MSG" \
    "${WORKER_FLAGS[@]}" \
    > "$OUT" 2>> "$MISSION_DIR/worker-stderr.log" || RC=$?
fi

# Surface the mission session's final text + exit metadata on stdout for the
# orchestrator's wake-up — ALWAYS, even when claude exited nonzero.
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
