#!/usr/bin/env bash
# Stop hook: when the ORCHESTRATOR session's context crosses the carryover
# threshold during an active mission, remind it (once) to write CARRYOVER.md
# and hand off to a fresh session. Silent no-op everywhere else.

set -euo pipefail

# Worker sessions set ORC_WORKER=1 (spawn-worker.sh); never fire for them.
[[ -n "${ORC_WORKER:-}" ]] && exit 0

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
[[ -n "$CWD" && -f "$TRANSCRIPT" ]] || exit 0

# Find the hub by nearest-ancestor search.
HUB=""
DIR="$CWD"
while [[ "$DIR" != "/" ]]; do
  if [[ -f "$DIR/.orchestrator/MISSION.md" ]]; then HUB="$DIR/.orchestrator"; break; fi
  DIR="$(dirname "$DIR")"
done
[[ -n "$HUB" ]] || exit 0

# Only during an active mission, and only once per mission.
grep -q '^\- \*\*Phase:\*\* complete' "$HUB/MISSION.md" && exit 0
MARKER="$HUB/.carryover-notified"
[[ -f "$MARKER" ]] && exit 0

BUDGET="${ORC_CONTEXT_BUDGET:-200000}"
THRESHOLD_PCT="${ORC_CARRYOVER_PCT:-65}"

# Context used ≈ token usage of the latest assistant message in the transcript.
USED="$(jq -s '
  [ .[] | select(.message.usage != null) | .message.usage ] | last // empty
  | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
    + (.cache_read_input_tokens // 0) + (.output_tokens // 0)
' "$TRANSCRIPT" 2>/dev/null || echo 0)"
[[ "$USED" =~ ^[0-9]+$ ]] || exit 0

PCT=$(( USED * 100 / BUDGET ))
(( PCT >= THRESHOLD_PCT )) || exit 0

touch "$MARKER"
jq -n --arg reason "[orchestrator context-watch] Main-session context is at ${PCT}% (threshold ${THRESHOLD_PCT}%). Execute the Carryover section of orchestrator:orchestrating NOW: write ${HUB}/CARRYOVER.md from the template, update MISSION.md, then tell the user: \"Context at ${THRESHOLD_PCT}% — open a new session and run /orchestrate to continue. Workers are unaffected.\" Do not start new work." \
  '{decision: "block", reason: $reason}'
exit 0
