#!/usr/bin/env bash
# Behavioral boundary tests for the shared Hybrid 0.3 launcher.
set -uo pipefail
SPAWN="$(cd "$(dirname "$0")/.." && pwd)/scripts/spawn-worker.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; WT="$TMP/worktree"; MD="$TMP/mission"; CONTROL="$TMP/control"
mkdir -p "$MD" "$CONTROL" "$TMP/bin"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" worktree add -q -b orc/hybrid-test "$WT"
printf '%s\t%s\t%s\t%s\n' "$WT" orc/hybrid-test "$BASE" "$REPO" > "$CONTROL/worktrees.txt"
cp "$CONTROL/worktrees.txt" "$MD/worktrees.txt"
printf 'approved design\n' > "$CONTROL/approved-design.md"
printf 'approved plan\n' > "$CONTROL/approved-plan.md"
printf 'APPROVED EXEC BRIEF\n' > "$CONTROL/brief-exec.md"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md > approved.sha256)
printf 'UNTRUSTED EXEC BRIEF\n' > "$MD/brief-exec.md"
printf 'FABLE BRIEF\n' > "$MD/brief.md"
printf 'session_id: 00000000-0000-4000-8000-000000000001\nbackend: claude-headless\nstage: plan\n' > "$MD/session.txt"
mkdir -p "$WT/.claude"
printf '{}\n' > "$WT/.claude/settings.local.json"
shasum -a 256 "$WT/.claude/settings.local.json" | awk '{print $1}' > "$CONTROL/worker-settings.sha256"

FAKE_CODEX="$TMP/bin/fake-codex"
cat > "$FAKE_CODEX" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ORC_FAKE_CODEX_ARGS"
LAST=""; WANT_LAST=0
for ARG in "$@"; do
  if [[ "$WANT_LAST" -eq 1 ]]; then LAST="$ARG"; WANT_LAST=0; continue; fi
  [[ "$ARG" == "--output-last-message" ]] && WANT_LAST=1
done
cat > "$ORC_FAKE_CODEX_STDIN"
printf 'EXECUTION DONE\n' > "$LAST"
printf '%s\n' '{"type":"thread.started","thread_id":"019f0000-0000-7000-8000-000000000003"}'
FAKE
chmod +x "$FAKE_CODEX"
export ORC_CODEX_BIN="$FAKE_CODEX"
export ORC_FAKE_CODEX_ARGS="$TMP/codex-args.log"
export ORC_FAKE_CODEX_STDIN="$TMP/codex-stdin.log"

N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

OUT="$("$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage exec)"
check "exec consumes coordinator-approved brief" 'grep -q "APPROVED EXEC BRIEF" "$TMP/codex-stdin.log" && ! grep -q "UNTRUSTED" "$TMP/codex-stdin.log"'
check "exec pins Sol and temp-root exclusions" 'grep -q "gpt-5.6-sol" "$TMP/codex-args.log" && grep -q "exclude_slash_tmp=true" "$TMP/codex-args.log" && grep -q "exclude_tmpdir_env_var=true" "$TMP/codex-args.log"'
check "exec records resumable thread" 'grep -q "codex_thread_id: 019f0000-0000-7000-8000-000000000003" "$MD/session.txt"'

printf 'tampered plan\n' > "$CONTROL/approved-plan.md"
if "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage exec >/dev/null 2>"$TMP/hash-error"; then HASH_RC=0; else HASH_RC=$?; fi
check "tampered approved contract is rejected" '[[ "$HASH_RC" -ne 0 ]] && grep -q "hash mismatch" "$TMP/hash-error"'
printf 'approved plan\n' > "$CONTROL/approved-plan.md"
(cd "$CONTROL" && shasum -a 256 approved-design.md approved-plan.md brief-exec.md > approved.sha256)

cp "$CONTROL/worktrees.txt" "$MD/worktrees.txt"
printf '#!/usr/bin/env bash\nset -eu\nprintf "<%%s>\\n" "$@" > "$ORC_FAKE_CLAUDE_ARGS"\ncat > "$ORC_FAKE_CLAUDE_STDIN"\nprintf "%%s\\n" '\''{"is_error":false,"num_turns":1,"result":"PLAN READY"}'\''\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
export ORC_FAKE_CLAUDE_ARGS="$TMP/claude-args.log"
export ORC_FAKE_CLAUDE_STDIN="$TMP/claude-stdin.log"
PATH="$TMP/bin:$PATH" OUT="$(PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT")"
check "Fable receives the planner brief" 'grep -q "FABLE BRIEF" "$TMP/claude-stdin.log"'
CLAUDE_ARG_TEXT="$(tr '\n' ' ' < "$TMP/claude-args.log")"
check "Fable has no Bash and no permission bypass" '[[ "$CLAUDE_ARG_TEXT" == *"Read"* && "$CLAUDE_ARG_TEXT" == *"Skill"* && "$CLAUDE_ARG_TEXT" != *"Bash"* && "$CLAUDE_ARG_TEXT" != *"dangerously-skip-permissions"* ]]'
check "Fable pins Fable-5 high" '[[ "$CLAUDE_ARG_TEXT" == *"claude-fable-5"* && "$CLAUDE_ARG_TEXT" == *"high"* ]]'

cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ORC_FAKE_CLAUDE_ARGS"
cat > "$ORC_FAKE_CLAUDE_STDIN"
SESSION_ID=""; WANT_SESSION_ID=0
for ARG in "$@"; do
  if [[ "$WANT_SESSION_ID" -eq 1 ]]; then SESSION_ID="$ARG"; WANT_SESSION_ID=0; continue; fi
  [[ "$ARG" == "--session-id" ]] && WANT_SESSION_ID=1
done
if [[ -n "$SESSION_ID" ]]; then
  if grep -qx "$SESSION_ID" "$ORC_FAKE_CLAUDE_SESSION_IDS" 2>/dev/null; then
    printf '%s\n' "Session ID $SESSION_ID is already in use"
    exit 3
  fi
  printf '%s\n' "$SESSION_ID" >> "$ORC_FAKE_CLAUDE_SESSION_IDS"
fi
if [[ "${ORC_FAKE_GENERIC_QUOTA:-}" == "1" ]]; then
  printf '%s\n' '{"is_error":true,"num_turns":1,"result":"Fable 5 is selected. You have reached your usage limit"}'
  exit 1
fi
case " $* " in
  *" --model claude-fable-5 "*)
    printf '%s\n' '{"is_error":true,"num_turns":1,"result":"You have reached your Fable 5 limit"}'
    exit 1
    ;;
  *" --model claude-opus-5 "*)
    printf '%s\n' '{"is_error":false,"num_turns":1,"result":"PLAN READY ON OPUS"}'
    ;;
  *)
    printf '%s\n' '{"is_error":true,"num_turns":1,"result":"unexpected model"}'
    exit 2
    ;;
esac
FAKE
chmod +x "$TMP/bin/claude"
export ORC_FAKE_CLAUDE_SESSION_IDS="$TMP/claude-session-ids.log"
: > "$ORC_FAKE_CLAUDE_SESSION_IDS"
: > "$TMP/claude-args.log"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null; then FALLBACK_FRESH_RC=0; else FALLBACK_FRESH_RC=$?; fi
check "fresh planning falls back from Fable quota to Opus" '[[ "$FALLBACK_FRESH_RC" -eq 0 ]] && grep -q "claude-fable-5" "$TMP/claude-args.log" && grep -q "claude-opus-5" "$TMP/claude-args.log"'
check "fresh planning records the model fallback" 'grep -q "model_fallback: claude-fable-5 -> claude-opus-5" "$MD/session.txt"'
check "fresh fallback mints a new Claude session ID" '[[ "$(grep -c "^session_id:" "$MD/session.txt")" -eq 2 ]] && [[ "$(sort -u "$ORC_FAKE_CLAUDE_SESSION_IDS" | wc -l | tr -d " ")" -eq 2 ]]'

: > "$TMP/claude-args.log"
export ORC_FAKE_GENERIC_QUOTA=1
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null; then GENERIC_QUOTA_RC=0; else GENERIC_QUOTA_RC=$?; fi
unset ORC_FAKE_GENERIC_QUOTA
check "generic usage quota does not switch to Opus" '[[ "$GENERIC_QUOTA_RC" -eq 75 ]] && grep -q "claude-fable-5" "$TMP/claude-args.log" && ! grep -q "claude-opus-5" "$TMP/claude-args.log"'

: > "$TMP/claude-args.log"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage review --resume review >/dev/null; then FALLBACK_RESUME_RC=0; else FALLBACK_RESUME_RC=$?; fi
check "review resume falls back from Fable quota to Opus" '[[ "$FALLBACK_RESUME_RC" -eq 0 ]] && grep -q "claude-fable-5" "$TMP/claude-args.log" && grep -q "claude-opus-5" "$TMP/claude-args.log"'
check "review resume records the model fallback" '[[ "$(grep -c "model_fallback: claude-fable-5 -> claude-opus-5" "$MD/session.txt")" -eq 1 ]]'

rm -f "$WT/.claude/settings.local.json"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage review --resume review >/dev/null 2>"$TMP/settings-missing-error"; then SETTINGS_MISSING_RC=0; else SETTINGS_MISSING_RC=$?; fi
check "missing local worker settings block Fable resume" '[[ "$SETTINGS_MISSING_RC" -ne 0 ]] && grep -q "worker settings missing" "$TMP/settings-missing-error"'

printf '{"tampered":true}\n' > "$WT/.claude/settings.local.json"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage review --resume review >/dev/null 2>"$TMP/settings-hash-error"; then SETTINGS_HASH_RC=0; else SETTINGS_HASH_RC=$?; fi
check "tampered local worker settings block Fable resume" '[[ "$SETTINGS_HASH_RC" -ne 0 ]] && grep -q "worker settings hash mismatch" "$TMP/settings-hash-error"'
printf '{}\n' > "$WT/.claude/settings.local.json"

printf '%s\t%s\t%s\t%s\n' "$TMP/evil" evil "$BASE" "$REPO" > "$MD/worktrees.txt"
if "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null 2>"$TMP/manifest-error"; then MANIFEST_RC=0; else MANIFEST_RC=$?; fi
check "worker manifest rewrite is rejected at launch" '[[ "$MANIFEST_RC" -ne 0 ]] && grep -q "does not match coordinator control" "$TMP/manifest-error"'

echo "  hybrid-spawn-worker: $OK/$N"
[[ "$OK" -eq "$N" ]]
