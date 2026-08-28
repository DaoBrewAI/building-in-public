#!/usr/bin/env bash
# PreToolUse guard for orchestrator CLAUDE mission sessions (plan/review stages;
# native Codex child tasks never load Claude hooks; their fence is the OS sandbox).
# Env (set by the hook command written into the PRIMARY worktree's settings):
#   ORC_WORKTREES   colon-separated absolute worktree roots (read-only context)
#   ORC_MISSION_DIR the mission's hub directory (the ONLY writable location)
# Claude stages plan and review — ALL code implementation belongs to the codex
# executor (founder directive 2026-08-07), so worktree writes and git commit are
# blocked here alongside branch-moving/publishing git verbs.
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

path_is_physically_inside_mission() { # <absolute target, may not exist>
  local TARGET="$1" CUR PARENT_PHYS MD_PHYS
  MD_PHYS="$(cd "$MD" && pwd -P)" || return 1
  [[ ! -L "$TARGET" ]] || return 1
  CUR="$TARGET"
  while [[ ! -e "$CUR" && ! -L "$CUR" ]]; do
    [[ "$CUR" != "/" ]] || return 1
    CUR="$(dirname "$CUR")"
  done
  # Any symlink component makes lexical authorization ambiguous; fail closed.
  local REL="${TARGET#"$MD"/}" COMPONENT PREFIX="$MD"
  OLDIFS="$IFS"; IFS='/'
  for COMPONENT in $REL; do
    PREFIX="$PREFIX/$COMPONENT"
    if [[ -L "$PREFIX" ]]; then
      IFS="$OLDIFS"
      return 1
    fi
  done
  IFS="$OLDIFS"
  if [[ -d "$CUR" ]]; then
    PARENT_PHYS="$(cd "$CUR" 2>/dev/null && pwd -P)" || return 1
  else
    PARENT_PHYS="$(cd "$(dirname "$CUR")" 2>/dev/null && pwd -P)" || return 1
  fi
  case "$PARENT_PHYS" in
    "$MD_PHYS"|"$MD_PHYS"/*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$TOOL" in
  Bash)
    deny "[orchestrator guard] Bash is unavailable to Fable brainstorm/plan/review stages. Use Read/Glob/Grep for read-only inspection and Write/Edit only for mission artifacts. The coordinator supplies trusted diffs for review; all implementation and write-producing tests belong to Codex."
    ;;
  Write|Edit|NotebookEdit)
    FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    if [[ -z "$FP" ]]; then
      deny "[orchestrator guard] could not determine target path; blocked defensively."
    fi
    case "$FP" in
      *"/../"*|*"/.."|"../"*|"..") deny "[orchestrator guard] paths containing '..' are blocked. Use absolute paths inside your mission directory." ;;
    esac
    # Relative paths resolve against the session cwd, which is the primary
    # worktree — i.e. a code write. Claude stages never write code.
    if [[ "$FP" != /* ]]; then
      deny "[orchestrator guard] relative-path write blocked: $FP would land in the worktree. The planner/reviewer session writes ONLY inside $MD — implementation belongs to the codex executor (record findings in report.md and set state=rework)."
    fi
    OLDIFS="$IFS"; IFS=':'
    for ROOT in $WTS; do
      if [[ -n "$ROOT" && "$FP" == "$ROOT"/* ]]; then
        IFS="$OLDIFS"
        deny "[orchestrator guard] worktree write blocked: $FP. ALL code implementation and fixes belong to the codex executor — record findings in report.md '## Code review' and set state=rework; the orchestrator bounces them to codex."
      fi
    done
    IFS="$OLDIFS"
    if [[ "$FP" == "$MD"/* ]]; then
      if path_is_physically_inside_mission "$FP"; then
        exit 0
      fi
      deny "[orchestrator guard] symlink or physical-path escape blocked: $FP. Mission artifact writes must remain physically inside $MD."
    fi
    deny "[orchestrator guard] write outside your sandbox blocked: $FP. You may only write inside your mission directory $MD (worktrees are read-only for claude stages). This includes all CLAUDE.md / memory files — the orchestrator owns memory."
    ;;
esac

exit 0
