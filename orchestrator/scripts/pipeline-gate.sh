#!/usr/bin/env bash
# Stop-hook artifact gate for orchestrator mission sessions.
# state=planned: blocks unless the Fable stage left design.md, plan.md, AND
#   plan-review.html (the Review Companion the founder reads at the go gate).
# state=review: blocks unless the pipeline left its artifacts behind: plan.md,
#   report.md sections, >=1 commit per branch.
# After 3 blocks it releases — the orchestrator's acceptance is the backstop.
# Env: ORC_MISSION_DIR and ORC_CONTROL_DIR (required), ORC_WORKTREES
# (informational). Commit checks use the coordinator-owned control manifest.

set -eo pipefail
trap 'exit 2' ERR   # unexpected failure -> blocking error, never a silent release

cat > /dev/null   # consume hook stdin; decisions are state-file driven

# Explicit check: a ${VAR:?} failure exits 1 WITHOUT firing the ERR trap, and
# exit 1 from a Stop hook is non-blocking (silent release). Fail closed instead.
if [[ -z "${ORC_MISSION_DIR:-}" || -z "${ORC_CONTROL_DIR:-}" ]]; then
  echo "[pipeline gate] misconfigured: ORC_MISSION_DIR / ORC_CONTROL_DIR not set" >&2
  exit 2
fi
MD="$ORC_MISSION_DIR"
CONTROL_MANIFEST="$ORC_CONTROL_DIR/worktrees.txt"
if [[ ! -s "$CONTROL_MANIFEST" || -L "$CONTROL_MANIFEST" ]]; then
  echo "[pipeline gate] coordinator control manifest missing, empty, or symlinked" >&2
  exit 2
fi

STATE="$(cat "$MD/state" 2>/dev/null || true)"

# P1-2 (2026-08-08 retrospective): a claude stage once ended its turn without
# writing any state (subagent still mid-flight) — state stayed `running`, the
# process died, and the orchestrator had to salvage it as a crash. Ending a
# turn in `running` is always incomplete: bounce it.
if [[ "$STATE" == "running" ]]; then
  BLOCKS="$(cat "$MD/.gate-blocks" 2>/dev/null || echo 0)"
  if [[ "$BLOCKS" -ge 3 ]]; then
    exit 0
  fi
  echo $((BLOCKS + 1)) > "$MD/.gate-blocks"
  jq -n --arg reason "[pipeline gate] You are ending your turn with state still 'running' — that loses the mission. Write your stage's terminal state to the state file first (plan stage: planned; review stage: rework or review) or follow the BLOCKED protocol, then end your turn." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

if [[ "$STATE" != "review" && "$STATE" != "planned" ]]; then
  exit 0
fi

MISSING=""
add() { MISSING="${MISSING}${1} · "; }

if [[ ! -f "$MD/plan.md" ]]; then
  add "plan.md is missing — run 10x-engineer:writing-plans and save the plan to $MD/plan.md"
fi

if [[ "$STATE" == "planned" ]]; then
  if [[ ! -s "$MD/design.md" ]]; then
    add "design.md is missing — invoke 10x-engineer:brainstorming and save the validated design to $MD/design.md before planning"
  fi
  if [[ ! -s "$MD/plan-review.html" ]]; then
    add "plan-review.html is missing — generate the writing-plans Review Companion HTML (decisions first with alternatives and likely-tweak/settled markers, mechanical work collapsed) and save it to $MD/plan-review.html; the founder reads it at the go gate"
  fi
  if [[ -z "$MISSING" ]]; then
    rm -f "$MD/.gate-blocks"
    exit 0
  fi
  BLOCKS="$(cat "$MD/.gate-blocks" 2>/dev/null || echo 0)"
  if [[ "$BLOCKS" -ge 3 ]]; then
    exit 0
  fi
  echo $((BLOCKS + 1)) > "$MD/.gate-blocks"
  jq -n --arg reason "[pipeline gate] You set state=planned but the plan stage is incomplete: ${MISSING}Fix these, then end your turn again." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

if [[ -f "$MD/report.md" ]]; then
  if ! grep -q '^## Code review' "$MD/report.md"; then
    add "report.md has no '## Code review' section — run the Fable same-session review checklist and record the verdict"
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

if [[ -f "$CONTROL_MANIFEST" ]]; then
  # `|| [[ -n "$WT" ]]` keeps a final manifest line that lacks a trailing
  # newline (read returns nonzero there but still fills the fields).
  while IFS=$'\t' read -r WT BRANCH BASE REPO || [[ -n "$WT" ]]; do
    if [[ -z "$WT" ]]; then continue; fi
    COUNT="$(git -C "$WT" rev-list --count "$BASE".."$BRANCH" 2>/dev/null || echo 0)"
    if [[ "$COUNT" -eq 0 ]]; then
      add "no commits on $BRANCH in $WT — commit your work"
    fi
  done < "$CONTROL_MANIFEST"
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
