#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
BRIEF="$ROOT/templates/brief-codex.md"
MEDIATION="$ROOT/skills/orchestrator-mediation/SKILL.md"

N=0
OK=0
check_contains() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if grep -Fqi -- "$literal" "$file"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_compact() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if tr '\n' ' ' < "$file" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

section_text() {
  local file="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    index($0, start) { inside = 1; next }
    inside && index($0, end) { exit }
    inside { print }
  ' "$file" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g'
}

check_section_contains() {
  local label="$1" file="$2" start="$3" end="$4" literal="$5" content
  N=$((N + 1))
  content="$(section_text "$file" "$start" "$end")"
  if printf '%s\n' "$content" | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_section_order() {
  local label="$1" file="$2" start="$3" end="$4" first="$5" second="$6" content
  N=$((N + 1))
  content="$(section_text "$file" "$start" "$end")"
  if printf '%s\n' "$content" | awk -v first="$first" -v second="$second" '
    {
      text = tolower($0)
      a = index(text, tolower(first))
      b = index(text, tolower(second))
      if (a > 0 && b > a) found = 1
    }
    END { exit(found ? 0 : 1) }
  '; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_section_contains "brainstorm classifies material unknowns before design" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'before writing design.md, classify whether an unanswered question could materially change scope, user-visible behavior, architecture, or success criteria'
check_section_contains "brainstorm clarification has a durable kind" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'kind: brainstorm-clarification'
check_section_contains "brainstorm asks exactly one question per round" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'exactly one question'
check_section_contains "brainstorm question provides mutually exclusive options" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  '2–3 mutually exclusive options'
check_section_contains "brainstorm question includes a recommendation" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'recommendation'
check_section_contains "brainstorm cannot write downstream artifacts before clarification" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'do not write design.md, plan.md, task-dag.json, or plan-review.html'
check_section_contains "brainstorm repeats classification after each answer" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'repeat this classification after every coordinator-provided answer'
check_section_contains "approved design keeps the direct planning fast path" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'explicitly approved current design'
check_section_order "clarification classification precedes design publication" \
  "$BRIEF" '## Stage 1A: BRAINSTORM' '## Stage 1B: PLAN' \
  'before writing design.md' 'save the resulting validated design'

check_section_contains "phase 3 permits clarification before plan artifacts" \
  "$SKILL" '## Phase 3 — Fable brainstorm and plan' '## Founder go gate' \
  'may return `blocked` with `kind: brainstorm-clarification`'
check_contains "coordinator relays unresolved brainstorm intent to user" \
  "$MEDIATION" 'relay exactly one question'
check_compact "coordinator does not self-decide brainstorm intent" \
  "$MEDIATION" 'never route it through reversible implementation detail or silently choose an option'
check_compact "coordinator reuses exact Fable session after answer" \
  "$MEDIATION" 'return the answer to the same Fable session'
check_compact "brainstorm clarification is not counted as ordinary implementation mediation" \
  "$MEDIATION" 'This is product-intent discovery'
check_contains "mediation recognizes brainstorm clarification before ordinary triage" \
  "$MEDIATION" '## (0) Brainstorm clarification — preserve user intent'
check_contains "mediation relays one unresolved intent question" \
  "$MEDIATION" 'relay exactly one question'
check_compact "mediation cannot consume brainstorm clarification as reversible detail" \
  "$MEDIATION" 'never route it through reversible implementation detail'
check_contains "founder go remains after completed design and plan" "$SKILL" '`planned` is the only planned human pause'

echo "  brainstorm-clarification-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
