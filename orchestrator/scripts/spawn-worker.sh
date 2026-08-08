#!/usr/bin/env bash
# Spawn (or resume) one stage of an orchestrator mission's staged pipeline.
#
#   spawn-worker.sh --mission-dir <dir> --worktree <primary> [--worktree <other>]...
#       fresh PLAN stage: claude (Fable-5) reads brief.md, plans, exits state=planned
#   spawn-worker.sh --mission-dir <dir> --worktree <primary> [...] --stage exec
#       fresh EXEC stage: codex (gpt-5.6-sol) reads brief-exec.md, implements plan.md,
#       exits state=executed
#   spawn-worker.sh ... --resume "<message>" [--stage review|exec]
#       resume: default backend is the claude session (mediation answers, the
#       executed->review trigger [--stage review labels it], crash salvage);
#       --stage exec resumes the codex thread instead
#
# The FIRST --worktree is the primary: it is the session cwd; for claude stages it
# holds the guard/gate hooks in its .claude/settings.json, for the exec stage it is
# the codex workspace-write sandbox root (other worktrees + mission dir via --add-dir).
# The orchestrator launches this via Bash with run_in_background:true and is woken
# when the process exits. On exit (any state) a macOS notification fires as the
# user-facing backup. Stdout ALWAYS carries either the stage summary or a
# diagnostic — never empty.

set -euo pipefail

MISSION_DIR="" RESUME_MSG="" STAGE=""
WORKTREES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --worktree)    WORKTREES+=("$2"); shift 2 ;;
    --resume)      RESUME_MSG="$2"; shift 2 ;;
    --stage)       STAGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$MISSION_DIR" || "${#WORKTREES[@]}" -eq 0 ]]; then
  echo "usage: --mission-dir <dir> --worktree <primary> [--worktree <other>]... [--stage plan|exec|review] [--resume <msg>]" >&2
  exit 1
fi
case "$STAGE" in
  ''|plan|exec|review) ;;
  *) echo "invalid --stage: $STAGE (plan|exec|review)" >&2; exit 1 ;;
esac
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

# Stage model specs are fixed by the plugin (founder directives 2026-07-22 + 2026-08-07):
# plan/review = Fable-5 high on claude; exec = gpt-5.6-sol reasoning-high on codex.
WORKER_FLAGS=(--model claude-fable-5 --effort high --dangerously-skip-permissions --output-format json)

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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# P1-1 (2026-08-08 retrospective): a worker killed by a usage/session limit
# exits nonzero with state stuck in running — surface it as a structured,
# retryable outcome (exit 75) instead of a crash.
detect_quota() { # <files...> — returns 0 and prints the hint line if matched
  local HINT
  HINT="$(grep -hoiE "(you've hit your [a-z]+ limit|session limit|usage limit|rate limit)[^\"]{0,80}" "$@" 2>/dev/null | head -1 || true)"
  if [[ -n "$HINT" ]]; then
    echo "QUOTA_LIMIT detected — retry_hint: $HINT"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- exec (codex)
if [[ "$STAGE" == "exec" ]]; then
  CODEX_BIN="${ORC_CODEX_BIN:-}"
  if [[ -z "$CODEX_BIN" ]]; then
    if command -v codex >/dev/null 2>&1; then
      CODEX_BIN="$(command -v codex)"
    elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
      CODEX_BIN="/Applications/ChatGPT.app/Contents/Resources/codex"
    else
      echo "codex CLI not found (PATH, ChatGPT.app bundle, or ORC_CODEX_BIN)" >&2
      exit 1
    fi
  fi
  # `codex exec resume` accepts no -s/--add-dir, so the sandbox is expressed as
  # -c config overrides, which BOTH forms accept identically: workspace-write
  # rooted at the cwd (primary worktree) plus the other worktrees and the
  # mission dir as extra writable roots. Network stays off unless ORC_CODEX_NETWORK.
  ROOTS=""
  # Index loop, not "${WORKTREES[@]:1}" — an empty slice trips set -u on bash 3.2.
  for ((i = 1; i < ${#WORKTREES[@]}; i++)); do
    ROOTS="${ROOTS}\"${WORKTREES[$i]}\", "
  done
  ROOTS="${ROOTS}\"$MISSION_DIR\""
  EXEC_FLAGS=(
    -m gpt-5.6-sol
    -c 'model_reasoning_effort="high"'
    -c 'sandbox_mode="workspace-write"'
    -c "sandbox_workspace_write.writable_roots=[$ROOTS]"
    --json
  )
  if [[ -n "${ORC_CODEX_NETWORK:-}" ]]; then
    EXEC_FLAGS+=(-c sandbox_workspace_write.network_access=true)
  fi

  if [[ ! -f "$SESSION_FILE" ]]; then
    echo "no session.txt in $MISSION_DIR — the plan stage must run before exec" >&2
    exit 1
  fi
  OUT="$(next_output)"
  LAST_MSG="${OUT%.json}.last.txt"
  {
    echo "stage: exec"
    echo "spawn_pid: $$"
  } >> "$SESSION_FILE"

  # P0-1: the codex sandbox cannot commit (git DB is read-only there) — run the
  # commit broker alongside the executor and drain any backlog after it exits.
  "$SCRIPT_DIR/commit-broker.sh" --mission-dir "$MISSION_DIR" \
    >> "$MISSION_DIR/broker.log" 2>&1 &
  BROKER_PID=$!
  stop_broker() {
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
    "$SCRIPT_DIR/commit-broker.sh" --mission-dir "$MISSION_DIR" --once \
      >> "$MISSION_DIR/broker.log" 2>&1 || true
  }

  if [[ -z "$RESUME_MSG" ]]; then
    if [[ ! -f "$MISSION_DIR/brief-exec.md" ]]; then
      stop_broker
      echo "no brief-exec.md in $MISSION_DIR" >&2
      exit 1
    fi
    echo "exec_spawned: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_FILE"
    cd "$PRIMARY"
    ORC_WORKER=1 "$CODEX_BIN" exec "${EXEC_FLAGS[@]}" --output-last-message "$LAST_MSG" - \
      < "$MISSION_DIR/brief-exec.md" \
      > "$OUT" 2>> "$MISSION_DIR/worker-stderr.log" || RC=$?
    THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id' "$OUT" 2>/dev/null | head -1 || true)"
    if [[ -n "$THREAD_ID" ]]; then
      echo "codex_thread_id: $THREAD_ID" >> "$SESSION_FILE"
    fi
  else
    THREAD_ID="$(awk -F': ' '/^codex_thread_id:/ {id=$2} END {print id}' "$SESSION_FILE")"
    if [[ -z "$THREAD_ID" ]]; then
      stop_broker
      echo "no codex_thread_id in $SESSION_FILE — cannot resume exec stage" >&2
      exit 1
    fi
    echo "exec_resumed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_FILE"
    cd "$PRIMARY"
    ORC_WORKER=1 "$CODEX_BIN" exec resume "$THREAD_ID" "${EXEC_FLAGS[@]}" \
      --output-last-message "$LAST_MSG" "$RESUME_MSG" \
      > "$OUT" 2>> "$MISSION_DIR/worker-stderr.log" || RC=$?
  fi
  stop_broker

  if [[ "$RC" -ne 0 ]] && detect_quota "$OUT" "$LAST_MSG" "$MISSION_DIR/worker-stderr.log"; then
    exit 75
  fi
  if [[ -s "$LAST_MSG" ]]; then
    echo "mission exec turn ended · backend=codex · rc=$RC"
    echo "---"
    cat "$LAST_MSG"
    exit "$RC"
  fi
  echo "codex exec produced no final message (exit=$RC) — last stderr lines:"
  tail -n 20 "$MISSION_DIR/worker-stderr.log" 2>/dev/null || true
  if [[ "$RC" -eq 0 ]]; then
    RC=1
  fi
  exit "$RC"
fi

# ------------------------------------------------------- plan/review (claude)
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
    echo "stage: plan"
    echo "spawn_pid: $$"
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
  SESSION_ID="$(awk -F': ' '/^session_id:/ {id=$2} END {print id}' "$SESSION_FILE")"
  if [[ -z "$SESSION_ID" ]]; then
    echo "no session_id in $SESSION_FILE" >&2
    exit 1
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
