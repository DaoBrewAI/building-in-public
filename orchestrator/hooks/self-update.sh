#!/usr/bin/env bash
# SessionStart hook: keep this plugin current with the building-in-public
# marketplace without anyone running `claude plugin update` by hand.
#
# Refreshes the marketplace clone and updates orchestrator in a detached
# background process, then returns immediately -- session start never waits on
# the network. Updates land on the NEXT session start, since Claude Code loads
# plugins before this hook runs.
#
# Silent no-op when: running inside a worker session, `claude` is not on PATH,
# the throttle window is still open, or ORC_NO_SELF_UPDATE=1.

set -uo pipefail

# Worker sessions set ORC_WORKER=1 (spawn-worker.sh); never fire for them.
[[ -n "${ORC_WORKER:-}" ]] && exit 0

# Explicit opt-out.
[[ "${ORC_NO_SELF_UPDATE:-}" == "1" ]] && exit 0

command -v claude >/dev/null 2>&1 || exit 0

STATE_DIR="${HOME}/.claude/plugins/cache"
STAMP="${STATE_DIR}/.orchestrator-self-update"
LOG="${STATE_DIR}/.orchestrator-self-update.log"
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

# Detach so a slow or offline network cannot stall session start. Scope is
# tried user-then-project because either may hold the install.
nohup bash -c '
  claude plugin marketplace update building-in-public
  claude plugin update orchestrator@building-in-public --scope user
  claude plugin update orchestrator@building-in-public --scope project
' >"$LOG" 2>&1 &
disown 2>/dev/null || true

exit 0
