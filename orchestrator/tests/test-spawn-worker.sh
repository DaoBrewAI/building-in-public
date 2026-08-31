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
printf 'pending\n' > "$MD/state"
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

opus_receipt_valid() {
  jq -e --arg session "$(cat "$CONTROL/planning-session-id")" 'keys == ["from","session_id","stage","to"] and .from == "claude-fable-5" and .to == "claude-opus-5" and .stage == "plan" and .session_id == $session' "$1" >/dev/null
}

receipt_sha_matches() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  [[ "$actual" == "$2" ]]
}

if ORC_SPAWN_TEST_FAIL_AFTER_AUTHORITY=1 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null 2>"$TMP/pre-running-failure"; then
  PRE_RUNNING_RC=0
else
  PRE_RUNNING_RC=$?
fi
check "pre-launch failure preserves pending with complete recoverable session authority" \
  '[[ "$PRE_RUNNING_RC" -ne 0 && "$(cat "$MD/state")" = pending && -s "$MD/session.txt" && "$(awk -F": " '\''/^session_id:/ {print $2; exit}'\'' "$MD/session.txt")" = "$(cat "$CONTROL/planning-session-id")" ]]'

PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null
check "Fable launcher transitions pending to running only after authority publication" \
  '[[ "$(cat "$MD/state")" = running ]]'
check "Fable receives the planner brief" 'grep -q "FABLE BRIEF" "$TMP/claude-stdin.log"'
CLAUDE_ARG_TEXT="$(tr '\n' ' ' < "$TMP/claude-args.log")"
check "Fable has no Bash and no permission bypass" '[[ "$CLAUDE_ARG_TEXT" == *"Read"* && "$CLAUDE_ARG_TEXT" == *"Skill"* && "$CLAUDE_ARG_TEXT" != *"Bash"* && "$CLAUDE_ARG_TEXT" != *"dangerously-skip-permissions"* ]]'
check "Fable pins Fable-5 high" '[[ "$CLAUDE_ARG_TEXT" == *"claude-fable-5"* && "$CLAUDE_ARG_TEXT" == *"high"* ]]'
check "Fable session identity is copied into coordinator authority" \
  '[[ "$(awk -F": " '\''/^session_id:/ {print $2; exit}'\'' "$MD/session.txt")" = "$(cat "$CONTROL/planning-session-id")" ]]'

SESSION_AFTER_LAUNCH_SHA="$(shasum -a 256 "$MD/session.txt" | awk '{print $1}')"
if PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" >/dev/null 2>"$TMP/duplicate-fresh"; then
  DUPLICATE_FRESH_RC=0
else
  DUPLICATE_FRESH_RC=$?
fi
check "fresh Fable launch requires pending and preserves the accepted session" \
  '[[ "$DUPLICATE_FRESH_RC" -ne 0 ]] && grep -q "requires pending" "$TMP/duplicate-fresh" && receipt_sha_matches "$MD/session.txt" "$SESSION_AFTER_LAUNCH_SHA"'

if ORC_PLAN_MODEL=unexpected PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --resume retry >/dev/null 2>"$TMP/model-error"; then
  MODEL_RC=0
else
  MODEL_RC=$?
fi
check "planner launcher rejects every model except Fable-5 and Opus-5" '[[ "$MODEL_RC" -ne 0 ]] && grep -q "unsupported planning model" "$TMP/model-error"'

if ORC_PLAN_MODEL=claude-opus-5 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --resume quota >/dev/null 2>"$TMP/opus-no-receipt"; then
  OPUS_NO_RECEIPT_RC=0
else
  OPUS_NO_RECEIPT_RC=$?
fi
check "Opus requires an explicit quota-fallback transition" '[[ "$OPUS_NO_RECEIPT_RC" -ne 0 ]] && grep -q "requires --quota-fallback" "$TMP/opus-no-receipt"'

ORC_PLAN_MODEL=claude-opus-5 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage plan --resume quota --quota-fallback >/dev/null
OPUS_RECEIPT="$CONTROL/quota-fallback-plan.json"
check "first Opus fallback publishes exact no-clobber stage/model receipt" 'opus_receipt_valid "$OPUS_RECEIPT"'
OPUS_RECEIPT_SHA="$(shasum -a 256 "$OPUS_RECEIPT" | awk '{print $1}')"

cp "$MD/session.txt" "$TMP/session-before-tamper"
sed 's/^session_id:.*/session_id: redirected-thread/' "$MD/session.txt" > "$TMP/session-tampered"
mv "$TMP/session-tampered" "$MD/session.txt"
if ORC_PLAN_MODEL=claude-opus-5 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage plan --resume continue --quota-fallback >/dev/null 2>"$TMP/opus-session-mismatch"; then
  OPUS_SESSION_MISMATCH_RC=0
else
  OPUS_SESSION_MISMATCH_RC=$?
fi
check "Opus fallback cannot resume a worker-swapped session id" \
  '[[ "$OPUS_SESSION_MISMATCH_RC" -ne 0 ]] && grep -q "planning session authority mismatch" "$TMP/opus-session-mismatch"'
mv "$TMP/session-before-tamper" "$MD/session.txt"

if ORC_PLAN_MODEL=claude-opus-5 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage plan --quota-fallback >/dev/null 2>"$TMP/opus-second-fresh"; then
  OPUS_SECOND_FRESH_RC=0
else
  OPUS_SECOND_FRESH_RC=$?
fi
check "consumed Opus fallback cannot launch a second fresh session" '[[ "$OPUS_SECOND_FRESH_RC" -ne 0 ]] && grep -q "already consumed" "$TMP/opus-second-fresh"'

ORC_PLAN_MODEL=claude-opus-5 PATH="$TMP/bin:$PATH" "$SPAWN" --mission-dir "$MD" --control-dir "$CONTROL" --worktree "$WT" --stage plan --resume continue --quota-fallback >/dev/null
check "same Opus fallback session may resume without rewriting its receipt" 'receipt_sha_matches "$OPUS_RECEIPT" "$OPUS_RECEIPT_SHA"'

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
