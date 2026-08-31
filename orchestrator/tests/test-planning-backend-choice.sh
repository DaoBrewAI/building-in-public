#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
PLANNING="$ROOT/skills/orchestrating/references/planning-and-review.md"
MISSION="$ROOT/templates/MISSION.md"
BRIEF="$ROOT/templates/brief-codex.md"
README="$ROOT/README.md"

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}
contains() { grep -Fq -- "$2" "$1"; }
compact() { tr '\n' ' ' < "$1" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$2"; }

check "backend selection precedes every mission phase" python3 - "$SKILL" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
choice = text.index("## Entry — planning/review backend")
external = text.index("## External planning mode")
phase_zero = text.index("## Phase 0 — reconcile")
raise SystemExit(0 if choice < external < phase_zero else 1)
PY

check "new mission asks exactly two backend options" python3 - "$SKILL" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
section = text.split("## Entry — planning/review backend", 1)[1].split("\n## ", 1)[0]
options = re.findall(r"^\d+\. \*\*(.+?)\*\*", section, flags=re.M)
expected = ["Fable / Opus", "GPT-5.6-Sol Ultra"]
raise SystemExit(0 if options == expected else 1)
PY

check "explicit choice avoids a redundant question" compact "$SKILL" \
  'If the user already selected one option in the invocation, do not ask again'
check "existing mission reuses durable choice" compact "$SKILL" \
  'If an existing mission has matching planning-backend authority, reuse it without asking'
check "new mission cannot silently default" compact "$SKILL" \
  'Do not select a default or continue a new mission until the user chooses'
check "choice is mission scoped and immutable" compact "$SKILL" \
  'Persist exactly one immutable planning-backend value in both mission and control'
check "only two durable values are valid" compact "$SKILL" \
  '`fable-opus` or `codex-ultra`'

check "planning details use progressive disclosure" contains "$SKILL" \
  'references/planning-and-review.md'
check "Fable route preserves Fable model" compact "$PLANNING" \
  'Fable-5 high'
check "Fable route preserves Opus model" compact "$PLANNING" \
  'Opus-5 high'
check "Codex route creates a visible native task" compact "$PLANNING" \
  '`create_thread` under the coordinator saved project'
check "Codex route pins Sol" compact "$PLANNING" \
  '`model=gpt-5.6-sol`'
check "Codex route pins Ultra" compact "$PLANNING" \
  '`thinking=ultra`'
check "Codex route uses an independent context" compact "$PLANNING" \
  'visible planning/review task with its own context'
check "Codex route isolates accidental product writes" compact "$PLANNING" \
  '`environment=worktree`'
check "Codex route proves mission artifact access" compact "$PLANNING" \
  '`planning-writable-root-receipt`'
check "Codex route preserves product baselines" compact "$PLANNING" \
  'verify every product worktree remains clean and at its stage-entry tip'
check "Codex route reuses exact planning thread" compact "$PLANNING" \
  'reuse the same accepted thread for clarification, founder corrections, review, and re-review'
check "Codex review is independent from implementation" compact "$PLANNING" \
  'never implement or rework product code'
check "Codex native capability failure is explicit" compact "$PLANNING" \
  '`native-planning-task-api-unavailable`'
check "Codex selection never silently falls back to Claude" compact "$PLANNING" \
  'Never switch a selected backend without explicit user direction'
check "Codex planning task archives only after final review" compact "$PLANNING" \
  'archive the planning/review task only after the final verdict is durably accepted'
check "Codex session authority has an exact schema" compact "$PLANNING" \
  '`session.txt` contains exactly one each of `backend: codex-native`, `model: gpt-5.6-sol`, `effort: ultra`, `thread_id: <formal-id>`, and `stage: plan|review`'
check "Codex health authority is durable" compact "$PLANNING" \
  '`planning-thread-health.json`'
check "Codex bootstrap prompt is deterministic" compact "$PLANNING" \
  'Planning bootstrap only. Do not modify product files, Git, or create tasks'

check "implementation ownership remains Sol High" compact "$SKILL" \
  'GPT-5.6-Sol high owns every implementation, test-producing fix, and rework'
check "mission template records selected backend" contains "$MISSION" \
  '{{PLANNING_BACKEND_SPEC}}'
check "planning brief is backend neutral" compact "$BRIEF" \
  'selected planning/review session'
check "README documents both choices" compact "$README" \
  'Fable / Opus or GPT-5.6-Sol Ultra'

echo "  planning-backend-choice: $OK/$N"
[[ "$OK" -eq "$N" ]]
