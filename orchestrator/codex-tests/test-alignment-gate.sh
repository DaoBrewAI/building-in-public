#!/usr/bin/env bash
# Tests the coordinator-owned pre-merge and final artifact gates.
# shellcheck disable=SC2016,SC2034 # Assertions are deliberately evaluated after capture.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/codex-scripts/alignment-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MD="$TMP/mission"
mkdir -p "$MD"

run_gate() { GOUT="$("$GATE" --mission-dir "$MD" --stage "$1" 2>&1)"; GRC=$?; }
html() { printf '<!doctype html>\n<html lang="en"><body>evidence</body></html>\n' > "$1"; }

N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

# 1. Misconfiguration fails closed.
GOUT="$("$GATE" 2>&1)"; GRC=$?
check "missing args" '[[ "$GRC" -eq 2 ]]'

# 2. Routine pre-merge requires broker commit evidence and standalone truth HTML.
printf '%s\n' '- **Risk class:** routine' > "$MD/MISSION.md"
run_gate premerge
check "routine missing artifacts" '[[ "$GRC" -eq 1 && "$GOUT" == *commits.txt* && "$GOUT" == *status-truth-premerge.html* ]]'

# 3. A fragment is not accepted as durable standalone HTML.
printf 'feature-sha\n' > "$MD/commits.txt"
printf '<section>fragment only</section>\n' > "$MD/status-truth-premerge.html"
run_gate premerge
check "reject fragment" '[[ "$GRC" -eq 1 && "$GOUT" == *"standalone HTML"* ]]'

# 4. Routine pre-merge passes with broker evidence and valid standalone truth.
html "$MD/status-truth-premerge.html"
run_gate premerge
check "routine premerge pass" '[[ "$GRC" -eq 0 ]]'

# 5. Material pre-merge additionally requires walkthrough + quiz + approval.
printf '%s\n' '- **Risk class:** material' > "$MD/MISSION.md"
run_gate premerge
check "material alignment required" '[[ "$GRC" -eq 1 && "$GOUT" == *change-walkthrough.html* && "$GOUT" == *"Walkthrough quiz"* && "$GOUT" == *"Merge approval"* ]]'

# 6. Material pre-merge passes only after the durable alignment evidence exists.
html "$MD/change-walkthrough.html"
printf 'Walkthrough quiz: passed 6/6\nMerge approval: approved\n' > "$MD/coordinator-acceptance.md"
run_gate premerge
check "material premerge pass" '[[ "$GRC" -eq 0 ]]'

# 7. Final/archive gate requires acceptance, both truth files, and classified next steps.
run_gate final
check "final missing artifacts" '[[ "$GRC" -eq 1 && "$GOUT" == *status-truth.html* && "$GOUT" == *NEXT-STEPS.md* ]]'

# 8. Filled final artifacts pass.
html "$MD/status-truth.html"
printf '# Next steps\n\nNone\n' > "$MD/NEXT-STEPS.md"
run_gate final
check "final pass" '[[ "$GRC" -eq 0 ]]'

# 9. Unfilled next-step templates fail closed.
printf '# Next steps\n{{specific action}}\n' > "$MD/NEXT-STEPS.md"
run_gate final
check "reject templated next steps" '[[ "$GRC" -eq 1 && "$GOUT" == *"template placeholders"* ]]'

# 10. Concrete follow-ups must still carry an allowed classification.
printf '# Next steps\n\nInvestigate retry handling.\n' > "$MD/NEXT-STEPS.md"
run_gate final
check "reject unclassified next steps" '[[ "$GRC" -eq 1 && "$GOUT" == *"ready, decision-needed, deferred, or None"* ]]'

echo "  alignment-gate: $OK/$N"
[[ "$OK" -eq "$N" ]]
