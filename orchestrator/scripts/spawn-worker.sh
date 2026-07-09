#!/usr/bin/env bash
# Spawn (or resume) a headless worker session for one orchestrator task.
#
#   spawn-worker.sh --task-dir <hub task dir> --worktree <path>            # first spawn
#   spawn-worker.sh --task-dir <hub task dir> --worktree <path> --resume "<message>"
#
# Runs in the foreground of its own shell; the orchestrator launches it via
# Bash with run_in_background:true and is woken when the worker's turn ends.

set -euo pipefail

TASK_DIR="" WORKTREE="" RESUME_MSG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir) TASK_DIR="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --resume)   RESUME_MSG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TASK_DIR" && -n "$WORKTREE" ]] || { echo "usage: --task-dir <dir> --worktree <dir> [--resume <msg>]" >&2; exit 1; }
[[ -d "$WORKTREE" ]] || { echo "worktree not found: $WORKTREE" >&2; exit 1; }

# Worker spec is fixed by the orchestrator plugin: Opus 4.8, extra-high effort,
# permissions skipped (the PreToolUse guard in the worktree's settings is the fence).
WORKER_FLAGS=(--model claude-opus-4-8 --effort xhigh --dangerously-skip-permissions --output-format json)

SESSION_FILE="$TASK_DIR/session.txt"

if [[ -z "$RESUME_MSG" ]]; then
  [[ -f "$TASK_DIR/brief.md" ]] || { echo "no brief.md in $TASK_DIR" >&2; exit 1; }
  SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  {
    echo "session_id: $SESSION_ID"
    echo "backend: claude-headless"
    echo "spawned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$SESSION_FILE"
  N="$(find "$TASK_DIR" -maxdepth 1 -name 'worker-output-*.json' | wc -l | tr -d ' ')"
  OUT="$TASK_DIR/worker-output-$((N + 1)).json"
  cd "$WORKTREE"
  ORC_WORKER=1 claude -p "$(cat "$TASK_DIR/brief.md")" \
    --session-id "$SESSION_ID" "${WORKER_FLAGS[@]}" \
    > "$OUT" 2>> "$TASK_DIR/worker-stderr.log"
else
  [[ -f "$SESSION_FILE" ]] || { echo "no session.txt to resume in $TASK_DIR" >&2; exit 1; }
  SESSION_ID="$(awk -F': ' '/^session_id:/ {print $2}' "$SESSION_FILE")"
  [[ -n "$SESSION_ID" ]] || { echo "no session_id in $SESSION_FILE" >&2; exit 1; }
  echo "resumed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SESSION_FILE"
  N="$(find "$TASK_DIR" -maxdepth 1 -name 'worker-output-*.json' | wc -l | tr -d ' ')"
  OUT="$TASK_DIR/worker-output-$((N + 1)).json"
  cd "$WORKTREE"
  ORC_WORKER=1 claude -p --resume "$SESSION_ID" "$RESUME_MSG" \
    "${WORKER_FLAGS[@]}" \
    > "$OUT" 2>> "$TASK_DIR/worker-stderr.log"
fi

# Surface the worker's final text + exit metadata for the orchestrator's wake-up.
jq -r '"worker turn ended · is_error=\(.is_error) · turns=\(.num_turns)\n---\n\(.result)"' "$OUT" 2>/dev/null \
  || { echo "worker produced no parseable JSON output — see worker-stderr.log"; exit 1; }
