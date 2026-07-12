#!/usr/bin/env bash
# PreToolUse guard for orchestrator mission sessions.
# Env (set by the hook command written into the PRIMARY worktree's settings):
#   ORC_WORKTREES   colon-separated absolute worktree roots (one per repo)
#   ORC_MISSION_DIR the mission's hub directory (also writable)
# Blocks branch-moving/publishing git verbs and any write outside the fence.
# Hooks fire even under --dangerously-skip-permissions, so this is the fence.

set -euo pipefail
trap 'exit 2' ERR

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if [[ -z "${ORC_WORKTREES:-}" || -z "${ORC_MISSION_DIR:-}" ]]; then
  deny "[orchestrator guard] misconfigured: ORC_WORKTREES / ORC_MISSION_DIR not set. Blocking defensively — tell the orchestrator via a BLOCKED file."
fi
WTS="$ORC_WORKTREES"
MD="$ORC_MISSION_DIR"

case "$TOOL" in
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    if printf '%s' "$CMD" | grep -qE '\bgit\b[^|;&]*\b(checkout|switch|merge|rebase|push)\b'; then
      deny "[orchestrator guard] git checkout/switch/merge/rebase/push are forbidden for mission sessions. Commit on your mission branches only; the orchestrator integrates. If you believe you need this, write a BLOCKED file instead."
    fi
    if printf '%s' "$CMD" | grep -qE '\bgit\b[^|;&]*\bworktree\b'; then
      deny "[orchestrator guard] mission sessions must not manage worktrees. Write a BLOCKED file if your workspace looks wrong."
    fi
    ;;
  Write|Edit|NotebookEdit)
    FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    if [[ -z "$FP" ]]; then
      deny "[orchestrator guard] could not determine target path; blocked defensively."
    fi
    case "$FP" in
      *"/../"*|*"/.."|"../"*|"..") deny "[orchestrator guard] paths containing '..' are blocked. Use absolute paths inside your worktrees." ;;
    esac
    # Relative paths resolve against the session cwd, which is the primary worktree.
    if [[ "$FP" != /* ]]; then
      exit 0
    fi
    OLDIFS="$IFS"; IFS=':'
    for ROOT in $WTS; do
      if [[ -n "$ROOT" && "$FP" == "$ROOT"/* ]]; then IFS="$OLDIFS"; exit 0; fi
    done
    IFS="$OLDIFS"
    if [[ "$FP" == "$MD"/* ]]; then
      exit 0
    fi
    deny "[orchestrator guard] write outside your sandbox blocked: $FP. You may only write inside your mission worktrees ($WTS) and $MD. This includes all CLAUDE.md / memory files — the orchestrator owns memory."
    ;;
esac

exit 0
