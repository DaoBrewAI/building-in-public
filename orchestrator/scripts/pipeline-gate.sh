#!/usr/bin/env bash
# Stop-hook artifact gate for orchestrator mission sessions.
# Blocks the session from ending its turn in state=review unless the pipeline
# left its artifacts behind: plan.md, report.md sections, >=1 commit per branch.
# After 3 blocks it releases — the orchestrator's acceptance is the backstop.
# Env: ORC_MISSION_DIR (required), ORC_WORKTREES (informational; commit checks
# use the worktrees.txt manifest written at provision time).

set -eo pipefail
trap 'exit 2' ERR   # unexpected failure -> blocking error, never a silent release

cat > /dev/null   # consume hook stdin; decisions are state-file driven

# Explicit check: a ${VAR:?} failure exits 1 WITHOUT firing the ERR trap, and
# exit 1 from a Stop hook is non-blocking (silent release). Fail closed instead.
if [[ -z "${ORC_MISSION_DIR:-}" ]]; then
  echo "[pipeline gate] misconfigured: ORC_MISSION_DIR not set" >&2
  exit 2
fi
MD="$ORC_MISSION_DIR"

STATE="$(cat "$MD/state" 2>/dev/null || true)"
if [[ "$STATE" != "review" ]]; then
  exit 0
fi

MISSING=""
add() { MISSING="${MISSING}${1} · "; }

if [[ ! -f "$MD/plan.md" ]]; then
  add "plan.md is missing — run 10x-engineer:writing-plans and save the plan to $MD/plan.md"
fi

if [[ -f "$MD/report.md" ]]; then
  if ! grep -q '^## Code review' "$MD/report.md"; then
    add "report.md has no '## Code review' section — run 10x-engineer:requesting-code-review and record the verdict"
  fi
  if ! grep -q '^## Verification' "$MD/report.md"; then
    add "report.md has no '## Verification' section — run the test suites and paste real output"
  fi
  # The orchestrator pre-copies the report template, so headings exist from t=0;
  # leftover {{...}} placeholders are the tell that it was never filled in.
  if grep -qF '{{' "$MD/report.md"; then
    add "report.md still contains unfilled {{...}} template placeholders — replace them with the real verdict and real test output"
  fi
else
  add "report.md is missing — fill it from the template in your mission directory"
fi

if [[ -f "$MD/worktrees.txt" ]]; then
  # `|| [[ -n "$WT" ]]` keeps a final manifest line that lacks a trailing
  # newline (read returns nonzero there but still fills the fields).
  while IFS=$'\t' read -r WT BRANCH BASE REPO || [[ -n "$WT" ]]; do
    if [[ -z "$WT" ]]; then continue; fi
    COUNT="$(git -C "$WT" rev-list --count "$BASE".."$BRANCH" 2>/dev/null || echo 0)"
    if [[ "$COUNT" -eq 0 ]]; then
      add "no commits on $BRANCH in $WT — commit your work"
    fi
  done < "$MD/worktrees.txt"
fi

if [[ -z "$MISSING" ]]; then
  rm -f "$MD/.gate-blocks"   # clean pass: next review cycle gets fresh protection
  exit 0
fi

BLOCKS="$(cat "$MD/.gate-blocks" 2>/dev/null || echo 0)"
if [[ "$BLOCKS" -ge 3 ]]; then
  exit 0   # release; acceptance will bounce it with specifics
fi
echo $((BLOCKS + 1)) > "$MD/.gate-blocks"

jq -n --arg reason "[pipeline gate] You set state=review but the pipeline is incomplete: ${MISSING}Fix these, update report.md, then end your turn again." \
  '{decision: "block", reason: $reason}'
exit 0
