#!/usr/bin/env bash
# PreToolUse guard for orchestrator worker sessions.
# Written into each worktree's .claude/settings.json by the orchestrator with
# ORC_WORKTREE and ORC_TASK_DIR set. Blocks branch-moving/publishing git verbs
# and any write outside the worktree + the worker's own hub task directory.
# Hooks fire even under --dangerously-skip-permissions, so this is the fence.

set -euo pipefail

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

WT="${ORC_WORKTREE:?ORC_WORKTREE not set}"
TD="${ORC_TASK_DIR:?ORC_TASK_DIR not set}"

case "$TOOL" in
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    if printf '%s' "$CMD" | grep -qE '\bgit\b[^|;&]*\b(checkout|switch|merge|rebase|push)\b'; then
      deny "[orchestrator guard] git checkout/switch/merge/rebase/push are forbidden for workers. Commit on your branch only; the orchestrator integrates. If you believe you need this, write a BLOCKED file instead."
    fi
    if printf '%s' "$CMD" | grep -qE '\bgit\b[^|;&]*\bworktree\b'; then
      deny "[orchestrator guard] workers must not manage worktrees. Write a BLOCKED file if your workspace looks wrong."
    fi
    ;;
  Write|Edit|NotebookEdit)
    FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    [[ -n "$FP" ]] || deny "[orchestrator guard] could not determine target path; blocked defensively."
    case "$FP" in
      *"/../"*|*"/.."|"../"*|"..") deny "[orchestrator guard] paths containing '..' are blocked. Use absolute paths inside your worktree." ;;
    esac
    # Relative paths resolve against the worker's cwd, which is the worktree.
    if [[ "$FP" != /* ]]; then
      exit 0
    fi
    if [[ "$FP" == "$WT"/* || "$FP" == "$TD"/* ]]; then
      exit 0
    fi
    deny "[orchestrator guard] write outside your sandbox blocked: $FP. You may only write inside $WT and $TD. This includes all CLAUDE.md / memory files — the orchestrator owns memory."
    ;;
esac

exit 0
