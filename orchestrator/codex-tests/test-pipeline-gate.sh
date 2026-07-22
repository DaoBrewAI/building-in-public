#!/usr/bin/env bash
# Tests for scripts/pipeline-gate.sh — the Stop-hook artifact gate.
# shellcheck disable=SC2016,SC2034 # Assertions are deliberately evaluated after capture.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/codex-scripts/pipeline-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MD="$TMP/mission"; REPO="$TMP/repo"; CONTROL="$TMP/control-worktrees.txt"
mkdir -p "$MD"
git init -q "$REPO"
GITC=(git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
"${GITC[@]}" commit -q --allow-empty -m base
git -C "$REPO" checkout -q -b orc/test-mission
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\t%s\t%s\t%s\n' "$REPO" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
cp "$MD/worktrees.txt" "$CONTROL"
export ORC_MISSION_DIR="$MD" ORC_CONTROL_MANIFEST="$CONTROL"

# Sets GOUT (stdout) and GRC (exit code) — called outside $(...) so GRC survives.
run_gate() { GOUT="$(printf '{}' | "$GATE" 2>/dev/null)"; GRC=$?; }

N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

# 1. No state file -> silent pass-through (rc 0, no output)
run_gate
check "no state file"        '[[ "$GRC" -eq 0 && -z "$GOUT" ]]'

# 2. state=running -> silent pass-through
echo running > "$MD/state"
run_gate
check "state running"        '[[ "$GRC" -eq 0 && -z "$GOUT" ]]'

# 3. state=blocked -> silent pass-through
echo blocked > "$MD/state"
run_gate
check "state blocked"        '[[ "$GRC" -eq 0 && -z "$GOUT" ]]'

# 4. state=review, nothing present -> block, reason names plan.md and report.md
echo review > "$MD/state"
run_gate
check "blocks incomplete"    '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *plan.md* && "$GOUT" == *report.md* ]]'

# 5. all artifacts + a valid manifest -> silent pass-through. Commits are
# brokered only after this artifact gate passes.
touch "$MD/plan.md"
printf '<!doctype html>\n<html lang="en"><body>Plan review</body></html>\n' > "$MD/plan-review.html"
printf '## TDD evidence\nRED failed as expected; GREEN passed\n\n## Code review\nverdict: approved\n\n## Verification\n12 tests, 0 failures\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
run_gate
check "complete -> allow"    '[[ "$GRC" -eq 0 && -z "$GOUT" ]]'

# 6. missing report section still blocks, names the section
printf '## TDD evidence\nred/green\n\n## Verification\nok\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
run_gate
check "missing review section" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *"Code review"* ]]'

# 7. a missing manifest is incomplete even when plan/report are filled.
rm "$MD/worktrees.txt"
run_gate
check "missing manifest -> block" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *worktrees.txt* ]]'

# 8. an empty manifest is also incomplete.
: > "$MD/worktrees.txt"
run_gate
check "empty manifest -> block" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *empty* ]]'

# 9. template-blank report: both headings present but {{...}} placeholders left
#    (orchestrator pre-copies templates/report.md, so headings alone prove nothing).
printf '%s\t%s\t%s\t%s\n' "$REPO" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
printf '## TDD evidence\n{{red/green output}}\n\n## Code review\n{{verdict — approved/rejected + reviewer notes}}\n\n## Verification\n{{paste real test output}}\n\n## Deviations from the brief\n{{none or details}}\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\n{{none or details}}\n' > "$MD/report.md"
run_gate
check "unfilled placeholders -> block" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *unfilled* ]]'

# 10. a rewritten worker-facing manifest is rejected.
printf '%s\t%s\t%s\t%s\n' "$TMP/elsewhere" orc/evil deadbeef "$TMP/elsewhere" > "$MD/worktrees.txt"
printf '## TDD evidence\nred/green\n\n## Code review\napproved\n\n## Verification\nok\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
run_gate
check "manifest mismatch -> block" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *"control manifest"* ]]'

# 11. misconfig (ORC_MISSION_DIR unset) -> blocking error, exit 2
MOUT="$(printf '{}' | env -u ORC_MISSION_DIR "$GATE" 2>/dev/null)"; MRC=$?
check "misconfig exits 2"    '[[ "$MRC" -eq 2 ]]'

# 12. Missing TDD evidence is blocked even when review and verification exist.
printf '%s\t%s\t%s\t%s\n' "$REPO" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
printf '## Code review\napproved\n\n## Verification\nok\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
run_gate
check "missing TDD evidence" '[[ "$GRC" -eq 0 && "$GOUT" == *"block"* && "$GOUT" == *"TDD evidence"* ]]'

# 13. Deviations and follow-ups are durable handoff requirements.
printf '## TDD evidence\nred/green\n\n## Code review\napproved\n\n## Verification\nok\n' > "$MD/report.md"
run_gate
check "missing handoff sections" '[[ "$GRC" -eq 0 && "$GOUT" == *"block"* && "$GOUT" == *"Deviations"* && "$GOUT" == *"Suggested follow-ups"* ]]'

# 14. The writing-plans HTML review companion is mandatory.
printf '## TDD evidence\nred/green\n\n## Code review\napproved\n\n## Verification\nok\n\n## Deviations from the brief\nnone\n\n## Suggested follow-ups (for the orchestrator, not for you to do)\nnone\n' > "$MD/report.md"
rm "$MD/plan-review.html"
run_gate
check "missing plan review HTML" '[[ "$GRC" -eq 0 && "$GOUT" == *"block"* && "$GOUT" == *"plan-review.html"* ]]'

# 15. A fragment does not satisfy the durable standalone plan-review contract.
printf '<section>fragment only</section>\n' > "$MD/plan-review.html"
run_gate
check "reject plan review fragment" '[[ "$GRC" -eq 0 && "$GOUT" == *"block"* && "$GOUT" == *"standalone HTML"* ]]'

echo "  pipeline-gate: $OK/$N"
[[ "$OK" -eq "$N" ]]
