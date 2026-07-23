#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPAWN="$ROOT/codex-scripts/spawn-worker.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO_A="$TMP/repo-a"; REPO_B="$TMP/repo-b"
PRIMARY="$TMP/primary"; OTHER="$TMP/other"; MD="$TMP/mission"
CONTROL="$TMP/control-worktrees.txt"
mkdir -p "$MD"
for REPO in "$REPO_A" "$REPO_B"; do
  git init -q "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
done
BASE_A="$(git -C "$REPO_A" rev-parse HEAD)"
BASE_B="$(git -C "$REPO_B" rev-parse HEAD)"
git -C "$REPO_A" worktree add -q -b orc/test-a "$PRIMARY"
git -C "$REPO_B" worktree add -q -b orc/test-b "$OTHER"
printf '%s\t%s\t%s\t%s\n' "$PRIMARY" orc/test-a "$BASE_A" "$REPO_A" > "$MD/worktrees.txt"
printf '%s\t%s\t%s\t%s\n' "$OTHER" orc/test-b "$BASE_B" "$REPO_B" >> "$MD/worktrees.txt"
cp "$MD/worktrees.txt" "$CONTROL"
printf 'Implement the mission.\n' > "$MD/brief.md"
printf 'Implementation plan.\n' > "$MD/plan.md"
printf '<!doctype html>\n<html lang="en"><body>Plan review</body></html>\n' > "$MD/plan-review.html"
printf '## TDD evidence\nRED failed as expected; GREEN passed\n\n## Code review\napproved\n\n## Verification\nall tests passed\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
printf 'running\n' > "$MD/state"

FAKE="$TMP/fake-codex"
cat > "$FAKE" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ORC_FAKE_ARGS"
cat > "$ORC_FAKE_STDIN"
if [[ "$*" == *"exec resume"* ]]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"READY AFTER RESUME"}}'
else
  printf 'primary result\n' > "$ORC_FAKE_PRIMARY/result.txt"
  printf 'other result\n' > "$ORC_FAKE_OTHER/result.txt"
  printf 'review\n' > "$ORC_FAKE_MISSION/state"
  printf '%s\n' '{"type":"thread.started","thread_id":"019f0000-0000-7000-8000-000000000001"}'
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"READY FOR REVIEW"}}'
fi
FAKE_CODEX
chmod +x "$FAKE"

export ORC_CODEX_BIN="$FAKE"
export ORC_FAKE_ARGS="$TMP/args.log"
export ORC_FAKE_STDIN="$TMP/stdin.log"
export ORC_FAKE_PRIMARY="$PRIMARY" ORC_FAKE_OTHER="$OTHER" ORC_FAKE_MISSION="$MD"

OUT="$($SPAWN --mission-dir "$MD" --control-manifest "$CONTROL" --worktree "$PRIMARY" --worktree "$OTHER")"
[[ "$OUT" == *"READY FOR REVIEW"* ]]
grep -q '^thread_id: 019f0000-0000-7000-8000-000000000001$' "$MD/session.txt"
grep -q '^backend: codex-exec$' "$MD/session.txt"
grep -q -- 'exec --model gpt-5.6' "$TMP/args.log"
grep -q -- '--sandbox workspace-write' "$TMP/args.log"
grep -q -- 'approval_policy="never"' "$TMP/args.log"
! grep -q -- '--ask-for-approval' "$TMP/args.log"
grep -q -- 'sandbox_workspace_write.writable_roots=\[\]' "$TMP/args.log"
grep -q -- 'sandbox_workspace_write.exclude_slash_tmp=true' "$TMP/args.log"
grep -q -- 'sandbox_workspace_write.exclude_tmpdir_env_var=true' "$TMP/args.log"
! grep -q -- '--dangerously-bypass-hook-trust' "$TMP/args.log"
grep -q -- "--add-dir $MD" "$TMP/args.log"
grep -q -- "--add-dir $OTHER" "$TMP/args.log"
grep -q 'Implement the mission.' "$TMP/stdin.log"
[[ -f "$MD/worker-output-1.jsonl" ]]
[[ "$(git -C "$PRIMARY" rev-list --count "$BASE_A"..orc/test-a)" -eq 0 ]]
[[ "$(git -C "$OTHER" rev-list --count "$BASE_B"..orc/test-b)" -eq 0 ]]
[[ -f "$PRIMARY/result.txt" && -f "$OTHER/result.txt" ]]
[[ ! -f "$MD/commits.txt" ]]

OUT="$($SPAWN --mission-dir "$MD" --control-manifest "$CONTROL" --worktree "$PRIMARY" --worktree "$OTHER" --resume "continue")"
[[ "$OUT" == *"READY AFTER RESUME"* ]]
grep -q -- 'exec resume' "$TMP/args.log"
grep -q '019f0000-0000-7000-8000-000000000001' "$TMP/args.log"
[[ -f "$MD/worker-output-2.jsonl" ]]

echo "  spawn-worker: initial + resume passed"
