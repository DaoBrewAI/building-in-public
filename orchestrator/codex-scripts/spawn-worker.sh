#!/usr/bin/env bash
# Spawn or resume one autonomous Codex mission thread.
set -euo pipefail

MISSION_DIR="" CONTROL_MANIFEST="" RESUME_MSG=""
WORKTREES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir) MISSION_DIR="$2"; shift 2 ;;
    --control-manifest) CONTROL_MANIFEST="$2"; shift 2 ;;
    --worktree) WORKTREES+=("$2"); shift 2 ;;
    --resume) RESUME_MSG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$MISSION_DIR" || -z "$CONTROL_MANIFEST" || "${#WORKTREES[@]}" -eq 0 ]]; then
  echo "usage: --mission-dir <dir> --control-manifest <file> --worktree <primary> [--worktree <other>]... [--resume <msg>]" >&2
  exit 1
fi

PRIMARY="${WORKTREES[0]}"
for WT in "${WORKTREES[@]}"; do
  [[ -d "$WT" ]] || { echo "worktree not found: $WT" >&2; exit 1; }
done
[[ -d "$MISSION_DIR" ]] || { echo "mission directory not found: $MISSION_DIR" >&2; exit 1; }
[[ -s "$CONTROL_MANIFEST" && -f "$CONTROL_MANIFEST" && ! -L "$CONTROL_MANIFEST" ]] || {
  echo "coordinator control manifest missing, empty, or symlinked: $CONTROL_MANIFEST" >&2
  exit 1
}
cmp -s "$CONTROL_MANIFEST" "$MISSION_DIR/worktrees.txt" || {
  echo "worker manifest does not match coordinator control manifest" >&2
  exit 1
}
[[ ! "$CONTROL_MANIFEST" -ef "$MISSION_DIR/worktrees.txt" ]] || {
  echo "worker manifest must be a copy, not a hard link to coordinator authority" >&2
  exit 1
}
MISSION_PHYS="$(cd "$MISSION_DIR" && pwd -P)"
CONTROL_DIR_PHYS="$(cd "$(dirname "$CONTROL_MANIFEST")" && pwd -P)"
CONTROL_PHYS="$CONTROL_DIR_PHYS/$(basename "$CONTROL_MANIFEST")"
case "$CONTROL_PHYS" in
  "$MISSION_PHYS"/*) echo "control manifest must be outside the worker-writable mission directory" >&2; exit 1 ;;
esac

CONTROL_WORKTREES=()
while IFS=$'\t' read -r WT BRANCH BASE REPO EXTRA || [[ -n "${WT:-}" ]]; do
  [[ -n "$WT" && -n "$BRANCH" && -n "$BASE" && -n "$REPO" && -z "${EXTRA:-}" ]] || {
    echo "malformed coordinator control manifest" >&2
    exit 1
  }
  CONTROL_WORKTREES+=("$WT")
done < "$CONTROL_MANIFEST"
[[ "${#CONTROL_WORKTREES[@]}" -eq "${#WORKTREES[@]}" ]] || {
  echo "launcher worktrees do not match coordinator control manifest" >&2
  exit 1
}
for I in "${!WORKTREES[@]}"; do
  ARG_PHYS="$(cd "${WORKTREES[$I]}" && pwd -P)"
  MANIFEST_PHYS="$(cd "${CONTROL_WORKTREES[$I]}" && pwd -P)"
  [[ "$ARG_PHYS" == "$MANIFEST_PHYS" ]] || {
    echo "launcher worktrees do not match coordinator control manifest" >&2
    exit 1
  }
  case "$CONTROL_PHYS" in
    "$ARG_PHYS"/*) echo "control manifest must be outside worker-writable worktrees" >&2; exit 1 ;;
  esac
done

CODEX_BIN="${ORC_CODEX_BIN:-codex}"
command -v "$CODEX_BIN" >/dev/null 2>&1 || {
  echo "Codex CLI not found: $CODEX_BIN" >&2
  exit 1
}

MODEL="${ORC_CODEX_MODEL:-gpt-5.6}"
EFFORT="${ORC_CODEX_EFFORT:-xhigh}"
SESSION_FILE="$MISSION_DIR/session.txt"
STDERR_FILE="$MISSION_DIR/worker-stderr.log"

notify() {
  local STATE SLUG
  STATE="$(cat "$MISSION_DIR/state" 2>/dev/null || echo unknown)"
  SLUG="$(basename "$MISSION_DIR")"
  STATE="${STATE//\\/}"; STATE="${STATE//\"/}"; STATE="${STATE//$'\n'/ }"
  SLUG="${SLUG//\\/}"; SLUG="${SLUG//\"/}"; SLUG="${SLUG//$'\n'/ }"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"state: $STATE\" with title \"Codex Orchestrator: $SLUG\"" >/dev/null 2>&1 || true
  fi
}
trap notify EXIT

next_output() {
  local MAX=0 F N
  for F in "$MISSION_DIR"/worker-output-*.jsonl; do
    [[ -e "$F" ]] || continue
    N="${F##*worker-output-}"; N="${N%.jsonl}"
    case "$N" in
      ''|*[!0-9]*) ;;
      *) N="$((10#$N))"; (( N > MAX )) && MAX="$N" ;;
    esac
  done
  echo "$MISSION_DIR/worker-output-$((MAX + 1)).jsonl"
}

write_session() {
  local THREAD_ID="$1" NOW="$2" EVENT="$3" TMP
  TMP="$SESSION_FILE.tmp.$$"
  {
    [[ -f "$SESSION_FILE" ]] && grep '^superseded: ' "$SESSION_FILE" 2>/dev/null || true
    echo "thread_id: $THREAD_ID"
    echo "worker_pid: $$"
    echo "backend: codex-exec"
    echo "$EVENT: $NOW"
  } > "$TMP"
  mv "$TMP" "$SESSION_FILE"
}

COMMON_FLAGS=(
  --model "$MODEL"
  --config "model_reasoning_effort=\"$EFFORT\""
  --config 'sandbox_workspace_write.writable_roots=[]'
  --config 'sandbox_workspace_write.exclude_slash_tmp=true'
  --config 'sandbox_workspace_write.exclude_tmpdir_env_var=true'
  --enable multi_agent
  --json
)

OUT="$(next_output)"
RC=0
cd "$PRIMARY"

if [[ -z "$RESUME_MSG" ]]; then
  [[ -f "$MISSION_DIR/brief.md" ]] || { echo "no brief.md in $MISSION_DIR" >&2; exit 1; }
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_session pending "$NOW" spawned

  INITIAL_FLAGS=(
    "${COMMON_FLAGS[@]}"
    --sandbox workspace-write
    --ask-for-approval never
    --add-dir "$MISSION_DIR"
  )
  for WT in "${WORKTREES[@]:1}"; do
    INITIAL_FLAGS+=(--add-dir "$WT")
  done

  ORC_WORKER=1 "$CODEX_BIN" exec "${INITIAL_FLAGS[@]}" - \
    < "$MISSION_DIR/brief.md" \
    > "$OUT" 2>> "$STDERR_FILE" || RC=$?

  THREAD_ID="$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$OUT" 2>/dev/null | head -n 1)"
  if [[ -n "$THREAD_ID" ]]; then
    write_session "$THREAD_ID" "$NOW" spawned
  fi
else
  [[ -f "$SESSION_FILE" ]] || { echo "no session.txt to resume in $MISSION_DIR" >&2; exit 1; }
  THREAD_ID="$(awk -F': ' '/^thread_id:/ {print $2}' "$SESSION_FILE")"
  if [[ -z "$THREAD_ID" || "$THREAD_ID" == pending ]]; then
    echo "no resumable thread_id in $SESSION_FILE" >&2
    exit 1
  fi
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_session "$THREAD_ID" "$NOW" resumed
  ORC_WORKER=1 "$CODEX_BIN" exec resume \
    "${COMMON_FLAGS[@]}" "$THREAD_ID" "$RESUME_MSG" \
    > "$OUT" 2>> "$STDERR_FILE" || RC=$?
fi

if [[ "$RC" -eq 0 && "$(cat "$MISSION_DIR/state" 2>/dev/null || true)" == "review" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  GATE_OUT="$(printf '{}' | ORC_MISSION_DIR="$MISSION_DIR" ORC_CONTROL_MANIFEST="$CONTROL_MANIFEST" "$SCRIPT_DIR/pipeline-gate.sh")"
  if [[ -n "$GATE_OUT" ]]; then
    printf '%s\n' "$GATE_OUT" >> "$STDERR_FILE"
    RC=1
  fi
fi

SUMMARY="$(jq -sr '
  [ .[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text ]
  | last // empty
' "$OUT" 2>/dev/null || true)"

if [[ -n "$SUMMARY" ]]; then
  printf 'mission turn ended · codex exit=%s\n---\n%s\n' "$RC" "$SUMMARY"
  exit "$RC"
fi

echo "mission thread produced no final agent message (codex exit=$RC) — last stderr lines:"
tail -n 20 "$STDERR_FILE" 2>/dev/null || true
[[ "$RC" -ne 0 ]] || RC=1
exit "$RC"
