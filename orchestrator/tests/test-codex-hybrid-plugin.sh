#!/usr/bin/env bash
# Contract test for the Codex-facing Hybrid 0.3 orchestrator release.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/.codex-plugin/plugin.json"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
README="$ROOT/README.md"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
CLAUDE_SKILL="$ROOT/claude-skills/orchestrating/SKILL.md"
SPAWN="$ROOT/scripts/spawn-worker.sh"
GUARD="$ROOT/scripts/worker-guard.sh"
CODEX_BRIEF="$ROOT/templates/brief-codex.md"

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

json_field_is() {
  local file="$1" field="$2" expected="$3"
  python3 - "$file" "$field" "$expected" <<'PY'
import json
import sys

path, field, expected = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)[field]
raise SystemExit(0 if value == expected else 1)
PY
}

contains() {
  local file="$1" literal="$2"
  grep -Fq -- "$literal" "$file"
}

not_contains() {
  local file="$1" literal="$2"
  ! grep -Fq -- "$literal" "$file"
}

regex() {
  local file="$1" expression="$2"
  grep -Eq -- "$expression" "$file"
}

check "Codex manifest is version 0.3.0" \
  json_field_is "$MANIFEST" version 0.3.0
check "Codex manifest describes Claude Fable planning" \
  contains "$MANIFEST" "Fable-5"
check "Codex manifest describes GPT-5.6-Sol execution" \
  contains "$MANIFEST" "GPT-5.6-Sol"
check "Claude manifest delegates brainstorm to Fable" \
  contains "$CLAUDE_MANIFEST" "Fable-5 brainstorms"

check "Codex skill fixes Fable-5 as brainstorm/plan/review backend" \
  regex "$SKILL" 'brainstorm.*plan.*review.*claude-fable-5|claude-fable-5.*brainstorm.*plan.*review'
check "Codex skill fixes GPT-5.6-Sol as the only implementation backend" \
  regex "$SKILL" 'ALL code implementation.*gpt-5\.6-sol|gpt-5\.6-sol.*ALL code implementation'
check "Codex skill launches the shared 0.3 worker" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/spawn-worker.sh'
check "Hybrid launcher requires coordinator-owned control state" \
  contains "$SKILL" '--control-dir $HUB/control/<mission-slug>'
check "Codex skill provisions the executor brief" \
  contains "$SKILL" '$PLUGIN_DIR/templates/brief-exec.md'
check "Codex skill provisions the Fable brainstorm/plan brief" \
  contains "$SKILL" '$PLUGIN_DIR/templates/brief-codex.md'
check "Codex skill enforces the planned human go gate" \
  contains "$SKILL" 'state=planned'
check "Codex skill sends execution to the Codex stage" \
  contains "$SKILL" '--stage exec'
check "Codex skill resumes review on the Fable stage" \
  contains "$SKILL" '--stage review'
check "Codex skill bounces findings through rework" \
  contains "$SKILL" 'state=rework'
check "Codex skill limits non-converging rework" \
  regex "$SKILL" '3rd rework|three.*rework'
check "Codex skill documents legacy 0.2 compatibility" \
  contains "$SKILL" 'Legacy Codex 0.2 compatibility'
check "Pending legacy missions are detected without session history" \
  contains "$SKILL" 'no Hybrid 0.3 pipeline marker'
check "Go gate snapshots the approved contract outside worker roots" \
  contains "$SKILL" 'approved-design.md'

check "shared launcher hardcodes Fable-5 high" \
  contains "$SPAWN" 'WORKER_FLAGS=(--model claude-fable-5 --effort high'
check "shared launcher hardcodes GPT-5.6-Sol high" \
  contains "$SPAWN" '-m gpt-5.6-sol'
check "Fable launcher does not bypass permissions" \
  not_contains "$SPAWN" '--dangerously-skip-permissions'
check "Fable launcher exposes no Bash tool" \
  contains "$SPAWN" 'FABLE_TOOLS=(Read Glob Grep Write Edit Skill)'
check "shared launcher resumes the original Claude session" \
  contains "$SPAWN" 'claude -p --resume "$SESSION_ID"'
check "shared launcher resumes the original Codex thread" \
  contains "$SPAWN" 'exec resume "$THREAD_ID"'
check "shared launcher runs the commit broker" \
  contains "$SPAWN" 'commit-broker.sh" --mission-dir "$MISSION_DIR" --control-dir "$CONTROL_DIR"'
check "executor reads the immutable approved brief" \
  contains "$SPAWN" '< "$CONTROL_DIR/brief-exec.md"'
check "launcher verifies the approved contract hashes" \
  contains "$SPAWN" 'shasum -a 256 -c approved.sha256'
check "launcher rejects a hard-linked worker manifest" \
  contains "$SPAWN" 'worker manifest must be a copy, not a hard link'
check "Fable guard blocks worktree implementation" \
  contains "$GUARD" 'ALL code implementation and fixes belong to the codex executor'
check "Codex planner brief invokes Fable brainstorming" \
  contains "$CODEX_BRIEF" 'Invoke `10x-engineer:brainstorming`'
check "Codex planner brief makes Fable persist the design" \
  contains "$CODEX_BRIEF" 'save the resulting validated design to {{MISSION_DIR}}/design.md'
check "Fable review consumes coordinator-generated diffs without Bash" \
  contains "$CODEX_BRIEF" '{{REVIEW_DIFFS}}'
check "Fable review does not invoke a Task-dependent review skill" \
  not_contains "$CODEX_BRIEF" '10x-engineer:requesting-code-review'
check "Fable review runs an explicit same-session checklist" \
  contains "$CODEX_BRIEF" 'Same-session review checklist'
check "Claude coordinator records the ask instead of brainstorming it" \
  contains "$CLAUDE_SKILL" '## Phase 1 — Record the request'
check "Claude coordinator renders the same Fable brainstorm brief" \
  contains "$CLAUDE_SKILL" 'templates/brief-codex.md'
check "Claude coordinator lets missions share a repo in parallel" \
  contains "$CLAUDE_SKILL" 'Missions on one repo run in PARALLEL by default'
check "Claude coordinator queues only on a real dependency" \
  contains "$CLAUDE_SKILL" 'Dependency check (NOT a repo-exclusivity check)'
check "Codex coordinator lets missions share a repo in parallel" \
  contains "$SKILL" 'Missions sharing a repo run in PARALLEL'
check "Codex coordinator queues only on a real dependency" \
  contains "$SKILL" 'Sharing a repo with another mission is allowed'
check "Claude coordinator routes write-producing acceptance tests to Codex" \
  contains "$CLAUDE_SKILL" 'verification that may write caches, snapshots, coverage, or generated artifacts'

check "README declares Codex Hybrid 0.3" \
  contains "$README" 'Codex Hybrid 0.3'
check "README labels legacy Codex assets" \
  contains "$README" 'Legacy Codex 0.2 compatibility'

echo "  codex-hybrid-plugin: $OK/$N"
[[ "$OK" -eq "$N" ]]
