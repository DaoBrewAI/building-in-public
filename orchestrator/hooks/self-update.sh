#!/usr/bin/env bash
# SessionStart hook: keep EVERY building-in-public plugin current without
# anyone running `claude plugin update` by hand.
#
# Refreshes the marketplace clone, then updates every installed plugin whose
# marketplace is building-in-public -- discovered from installed_plugins.json,
# so a plugin added later is picked up with no change here. Runs detached and
# returns immediately: session start never waits on the network. Updates land
# on the NEXT session start, since Claude Code loads plugins before this hook.
#
# Silent no-op when: running inside a worker session, `claude` is not on PATH,
# the throttle window is still open, or ORC_NO_SELF_UPDATE=1.

set -uo pipefail

# Worker sessions set ORC_WORKER=1 (spawn-worker.sh); never fire for them.
[[ -n "${ORC_WORKER:-}" ]] && exit 0

# Explicit opt-out.
[[ "${ORC_NO_SELF_UPDATE:-}" == "1" ]] && exit 0

command -v claude >/dev/null 2>&1 || exit 0

MARKETPLACE="building-in-public"
STATE_DIR="${HOME}/.claude/plugins/cache"
STAMP="${STATE_DIR}/.orchestrator-self-update"
LOG="${STATE_DIR}/.orchestrator-self-update.log"
INSTALLED="${HOME}/.claude/plugins/installed_plugins.json"
THROTTLE_SECS="${ORC_SELF_UPDATE_INTERVAL:-21600}"   # 6h

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Throttle: one check per window, however many sessions get opened.
if [[ -f "$STAMP" ]]; then
  LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"
  [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
  NOW="$(date +%s)"
  (( NOW - LAST < THROTTLE_SECS )) && exit 0
fi
date +%s > "$STAMP" 2>/dev/null || true

# Every installed plugin from this marketplace, with the scopes it is installed
# under. Falls back to just this plugin if jq or the manifest is unavailable,
# so a broken read degrades to the old behavior instead of updating nothing.
TARGETS=""
if command -v jq >/dev/null 2>&1 && [[ -r "$INSTALLED" ]]; then
  TARGETS="$(jq -r --arg mp "@${MARKETPLACE}" '
    .plugins | to_entries[]
    | select(.key | endswith($mp))
    | .key as $name
    | .value[]
    | "\($name)\t\(.scope)"
  ' "$INSTALLED" 2>/dev/null | sort -u)"
fi
[[ -z "$TARGETS" ]] && TARGETS="orchestrator@${MARKETPLACE}"$'\t'"user"

# Detach so a slow or offline network cannot stall session start.
nohup bash -c '
  set -uo pipefail
  claude plugin marketplace update "'"$MARKETPLACE"'"
  while IFS=$'"'"'\t'"'"' read -r NAME SCOPE; do
    [[ -z "$NAME" ]] && continue
    claude plugin update "$NAME" --scope "${SCOPE:-user}"
  done <<< "'"$TARGETS"'"
' >"$LOG" 2>&1 &
disown 2>/dev/null || true

exit 0
