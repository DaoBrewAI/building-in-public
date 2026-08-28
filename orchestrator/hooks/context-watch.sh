#!/usr/bin/env bash
# Claude Code Stop hook: request native coordinator carryover once when an
# active mission crosses the configured context threshold.
set -euo pipefail

[[ -n "${ORC_WORKER:-}" ]] && exit 0
INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
[[ -n "$CWD" && -f "$TRANSCRIPT" ]] || exit 0

HUB=""
DIR="$CWD"
while [[ "$DIR" != / ]]; do
  if [[ -d "$DIR/.orchestrator" ]]; then HUB="$DIR/.orchestrator"; break; fi
  DIR="$(dirname "$DIR")"
done
[[ -n "$HUB" ]] || exit 0

ls "$HUB"/missions/*/state >/dev/null 2>&1 || exit 0
MARKER="$HUB/.carryover-notified"
[[ -f "$MARKER" ]] && exit 0

BUDGET="${ORC_CONTEXT_BUDGET:-1000000}"
THRESHOLD_PCT="${ORC_CARRYOVER_PCT:-65}"
USED="$(jq -s '
  [ .[] | select(.message.usage != null) | .message.usage ] | last // empty
  | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
    + (.cache_read_input_tokens // 0) + (.output_tokens // 0)
' "$TRANSCRIPT" 2>/dev/null || echo 0)"
[[ "$USED" =~ ^[0-9]+$ ]] || exit 0
PCT=$(( USED * 100 / BUDGET ))
(( PCT >= THRESHOLD_PCT )) || exit 0

touch "$MARKER"
jq -n --arg reason "[orchestrator context-watch] Context reached ${PCT}%. Follow the shared native orchestrating skill's Continuation section, persist durable state, and hand off before starting new work." \
  '{decision: "block", reason: $reason}'
