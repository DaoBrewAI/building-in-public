#!/usr/bin/env bash
# Post-turn artifact gate for orchestrator mission sessions.
# A sandboxed worker cannot write Git metadata, so this validates plan/report/
# manifest artifacts before the trusted wrapper invokes mission-commit.sh.
# Env: ORC_MISSION_DIR and ORC_CONTROL_MANIFEST (required).

set -eo pipefail
trap 'exit 2' ERR   # unexpected failure -> blocking error, never a silent release

cat > /dev/null   # consume hook stdin; decisions are state-file driven

# Explicit check: a ${VAR:?} failure exits 1 WITHOUT firing the ERR trap, and
# exit 1 from a Stop hook is non-blocking (silent release). Fail closed instead.
if [[ -z "${ORC_MISSION_DIR:-}" || -z "${ORC_CONTROL_MANIFEST:-}" ]]; then
  echo "[pipeline gate] misconfigured: ORC_MISSION_DIR or ORC_CONTROL_MANIFEST not set" >&2
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
  add "plan.md is missing — use 10x-engineer:writing-plans and save the plan to $MD/plan.md"
fi

if [[ -f "$MD/report.md" ]]; then
  if ! grep -q '^## Code review' "$MD/report.md"; then
    add "report.md has no '## Code review' section — use 10x-engineer:requesting-code-review and record the verdict"
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

if [[ ! -s "$ORC_CONTROL_MANIFEST" || -L "$ORC_CONTROL_MANIFEST" ]]; then
  add "coordinator control manifest is missing, empty, or symlinked"
elif [[ ! -f "$MD/worktrees.txt" ]]; then
  add "worktrees.txt is missing — the coordinator must restore the mission manifest"
elif [[ ! -s "$MD/worktrees.txt" ]]; then
  add "worktrees.txt is empty — the coordinator must restore the mission manifest"
elif ! cmp -s "$ORC_CONTROL_MANIFEST" "$MD/worktrees.txt"; then
  add "worktrees.txt does not match the coordinator control manifest — discard the worker rewrite and restore the copy"
fi

[[ -n "$MISSING" ]] || exit 0

jq -n --arg reason "[pipeline gate] The worker set state=review but the pipeline is incomplete: ${MISSING}Resume the worker with these exact corrections." \
  '{decision: "block", reason: $reason}'
exit 0
