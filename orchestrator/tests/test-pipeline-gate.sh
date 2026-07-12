#!/usr/bin/env bash
# Tests for scripts/pipeline-gate.sh — the Stop-hook artifact gate.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/scripts/pipeline-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MD="$TMP/mission"; REPO="$TMP/repo"
mkdir -p "$MD"
git init -q "$REPO"
GITC=(git -C "$REPO" -c user.email=t@t -c user.name=t)
"${GITC[@]}" commit -q --allow-empty -m base
git -C "$REPO" checkout -q -b orc/test-mission
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s\t%s\t%s\t%s\n' "$REPO" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
export ORC_MISSION_DIR="$MD" ORC_WORKTREES="$REPO"

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

# 5. all artifacts + a commit past base -> silent pass-through
touch "$MD/plan.md"
printf '## Code review\nverdict: approved\n\n## Verification\n12 tests, 0 failures\n' > "$MD/report.md"
"${GITC[@]}" commit -q --allow-empty -m work
rm -f "$MD/.gate-blocks"
run_gate
check "complete -> allow"    '[[ "$GRC" -eq 0 && -z "$GOUT" ]]'

# 6. missing report section still blocks, names the section
printf '## Verification\nok\n' > "$MD/report.md"
rm -f "$MD/.gate-blocks"
run_gate
check "missing review section" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *"Code review"* ]]'

# 7. loop protection: blocks 1..3, then lets go on the 4th
rm -f "$MD/.gate-blocks"
run_gate; B1="$GOUT"
run_gate; B2="$GOUT"
run_gate; B3="$GOUT"
run_gate; B4="$GOUT"; R4="$GRC"
check "3 blocks then release" '[[ -n "$B1" && -n "$B2" && -n "$B3" && -z "$B4" && "$R4" -eq 0 ]]'

# 8. commit check isolated: docs complete, 0 commits past base -> block "no commits".
#    Manifest deliberately written WITHOUT a trailing newline (pins the read-loop fix).
REPO2="$TMP/repo2"
git init -q "$REPO2"
git -C "$REPO2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$REPO2" checkout -q -b orc/test-mission
BASE2="$(git -C "$REPO2" rev-parse HEAD)"
printf '%s\t%s\t%s\t%s' "$REPO2" "orc/test-mission" "$BASE2" "$REPO2" > "$MD/worktrees.txt"
printf '## Code review\nverdict: approved\n\n## Verification\nok\n' > "$MD/report.md"
rm -f "$MD/.gate-blocks"
run_gate
check "no commits -> block"  '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *"no commits"* ]]'

# 9. template-blank report: both headings present but {{...}} placeholders left
#    (orchestrator pre-copies templates/report.md, so headings alone prove nothing).
#    Manifest points back at REPO, which has a commit past base.
printf '%s\t%s\t%s\t%s\n' "$REPO" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
printf '## Code review\n{{verdict — approved/rejected + reviewer notes}}\n\n## Verification\n{{paste real test output}}\n' > "$MD/report.md"
rm -f "$MD/.gate-blocks"
run_gate
check "unfilled placeholders -> block" '[[ "$GRC" -eq 0 && "$GOUT" == *\"block\"* && "$GOUT" == *unfilled* ]]'

# 10. misconfig (ORC_MISSION_DIR unset) -> blocking error, exit 2
MOUT="$(printf '{}' | env -u ORC_MISSION_DIR "$GATE" 2>/dev/null)"; MRC=$?
check "misconfig exits 2"    '[[ "$MRC" -eq 2 ]]'

echo "  pipeline-gate: $OK/$N"
[[ "$OK" -eq "$N" ]]
