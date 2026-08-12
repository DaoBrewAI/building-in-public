#!/usr/bin/env bash
# Tests for scripts/worker-guard.sh — the PreToolUse fence.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/scripts/worker-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WT_A="$TMP/wt-a"; WT_B="$TMP/wt-b"; MD="$TMP/mission"
mkdir -p "$WT_A" "$WT_B" "$MD"
export ORC_WORKTREES="$WT_A:$WT_B" ORC_MISSION_DIR="$MD"

run()    { printf '%s' "$1" | "$GUARD" 2>/dev/null; }
denies() { local OUT; OUT="$(run "$1")"; [[ "$OUT" == *permissionDecision* && "$OUT" == *deny* ]]; }
allows() { local OUT; OUT="$(run "$1")"; [[ -z "$OUT" ]]; }
denies_unset() {
  local OUT
  OUT="$(printf '%s' "$1" | env -u ORC_WORKTREES -u ORC_MISSION_DIR "$GUARD" 2>/dev/null)"
  [[ "$OUT" == *permissionDecision* && "$OUT" == *deny* ]]
}

N=0; OK=0
check() {
  N=$((N + 1))
  if "$@"; then OK=$((OK + 1)); else echo "  case $N failed: $2"; fi
}

check denies '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check denies '{"tool_name":"Bash","tool_input":{"command":"git merge feature"}}'
check denies '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && git checkout main"}}'
check denies '{"tool_name":"Bash","tool_input":{"command":"git worktree add ../x"}}'
# All implementation belongs to the codex executor: claude stages may not
# commit or write into worktrees — only the mission dir (2026-08-07).
check denies '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg"}}'
check denies '{"tool_name":"Bash","tool_input":{"command":"git log --oneline"}}'
check denies "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf hacked > '$WT_A/source.swift'\"}}"
check denies "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i '' s/a/b/ '$WT_B/notes.md'\"}}"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_A/src/file.swift\"}}"
check denies "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WT_B/notes.md\"}}"
check allows "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD/report.md\"}}"
check allows "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$MD/plan.md\"}}"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/outside.md\"}}"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_A/../escape.md\"}}"
check denies '{"tool_name":"Write","tool_input":{}}'
check denies '{"tool_name":"Write","tool_input":{"file_path":"relative/inside/cwd.md"}}'
mkdir -p "$TMP/wt-a-evil"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/wt-a-evil/x.md\"}}"
check denies_unset "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WT_A/src/file.swift\"}}"

# A lexical mission-dir prefix must not permit a symlink escape.
ln -s "$WT_A" "$MD/worktree-link"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD/worktree-link/escaped.swift\"}}"
mkdir -p "$MD/safe"
check allows "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD/safe/artifact.md\"}}"
echo running > "$MD/state"
check allows "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD/state\"}}"
ln -s "$WT_A/source.swift" "$MD/state-link"
check denies "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD/state-link\"}}"

echo "  worker-guard: $OK/$N"
[[ "$OK" -eq "$N" ]]
