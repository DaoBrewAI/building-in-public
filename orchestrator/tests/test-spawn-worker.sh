#!/usr/bin/env bash
set -uo pipefail

SPAWN="$(cd "$(dirname "$0")/.." && pwd)/scripts/spawn-worker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; WT="$TMP/worktree"; MD="$TMP/mission"; CONTROL="$TMP/control"
mkdir -p "$MD" "$CONTROL" "$TMP/bin"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" worktree add -q -b orc/native-test "$WT"
printf '%s\t%s\t%s\t%s\n' "$WT" orc/native-test "$BASE" "$REPO" > "$CONTROL/worktrees.txt"
cp "$CONTROL/worktrees.txt" "$MD/worktrees.txt"
printf 'approved design\n' > "$CONTROL/approved-design.md"
printf 'approved plan\n' > "$CONTROL/approved-plan.md"
printf 'approved exec brief\n' > "$CONTROL/brief-exec.md"
printf '{}\n' > "$CONTROL/approved-task-dag.json"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)
printf 'FABLE BRIEF\n' > "$MD/brief.md"
printf 'session_id: 00000000-0000-4000-8000-000000000001\nbackend: claude-headless\nstage: plan\n' > "$MD/session.txt"
mkdir -p "$WT/.claude"
printf '{}\n' > "$WT/.claude/settings.local.json"
shasum -a 256 "$WT/.claude/settings.local.json" | awk '{print $1}' > "$CONTROL/worker-settings.sha256"

printf '#!/usr/bin/env bash\nset -eu\nprintf "<%%s>\\n" "$@" > "$ORC_FAKE_CLAUDE_ARGS"\ncat > "$ORC_FAKE_CLAUDE_STDIN"\nprintf "%%s\\n" '\''{"is_error":false,"num_turns":1,"result":"PLAN READY"}'\''\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
export ORC_FAKE_CLAUDE_ARGS="$TMP/claude-args.log"
export ORC_FAKE_CLAUDE_STDIN="$TMP/claude-stdin.log"

N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null
check "Fable receives the planner brief" 'grep -q "FABLE BRIEF" "$TMP/claude-stdin.log"'
CLAUDE_ARG_TEXT="$(tr '\n' ' ' < "$TMP/claude-args.log")"
check "Fable has no Bash and no permission bypass" '[[ "$CLAUDE_ARG_TEXT" == *"Read"* && "$CLAUDE_ARG_TEXT" == *"Skill"* && "$CLAUDE_ARG_TEXT" != *"Bash"* && "$CLAUDE_ARG_TEXT" != *"dangerously-skip-permissions"* ]]'
check "Fable pins Fable-5 high" '[[ "$CLAUDE_ARG_TEXT" == *"claude-fable-5"* && "$CLAUDE_ARG_TEXT" == *"high"* ]]'

if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage exec >/dev/null 2>"$TMP/exec-error"; then EXEC_RC=0; else EXEC_RC=$?; fi
check "retired hidden exec stage is rejected" '[[ "$EXEC_RC" -ne 0 ]] && grep -q "invalid --stage" "$TMP/exec-error"'

printf 'tampered plan\n' > "$CONTROL/approved-plan.md"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage review --resume review >/dev/null 2>"$TMP/hash-error"; then HASH_RC=0; else HASH_RC=$?; fi
check "review rejects a tampered approved contract" '[[ "$HASH_RC" -ne 0 ]] && grep -q "hash mismatch" "$TMP/hash-error"'
printf 'approved plan\n' > "$CONTROL/approved-plan.md"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256)

rm -f "$WT/.claude/settings.local.json"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage review --resume review >/dev/null 2>"$TMP/settings-error"; then SETTINGS_RC=0; else SETTINGS_RC=$?; fi
check "missing worker settings block Fable resume" '[[ "$SETTINGS_RC" -ne 0 ]] && grep -q "worker settings missing" "$TMP/settings-error"'

printf '{}\n' > "$WT/.claude/settings.local.json"
printf '%s\t%s\t%s\t%s\n' "$TMP/evil" evil "$BASE" "$REPO" > "$MD/worktrees.txt"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null 2>"$TMP/manifest-error"; then MANIFEST_RC=0; else MANIFEST_RC=$?; fi
check "worker manifest rewrite is rejected" '[[ "$MANIFEST_RC" -ne 0 ]] && grep -q "does not match coordinator control" "$TMP/manifest-error"'

echo "  hybrid-spawn-worker: $OK/$N"
[[ "$OK" -eq "$N" ]]
