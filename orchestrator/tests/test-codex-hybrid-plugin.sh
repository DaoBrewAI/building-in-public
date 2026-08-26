#!/usr/bin/env bash
# Contract test for the Codex-facing Orchestrator 0.4 release.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/.codex-plugin/plugin.json"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
README="$ROOT/README.md"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
CLAUDE_SKILL="$ROOT/claude-skills/orchestrating/SKILL.md"
SPAWN="$ROOT/scripts/spawn-worker.sh"
GUARD="$ROOT/scripts/worker-guard.sh"
INSTALLER="$ROOT/scripts/install-worker-settings.sh"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
INTEGRATE="$ROOT/scripts/integrate-task.sh"
VALIDATOR="$ROOT/scripts/validate-task-dag.sh"
TASK_CLIENT="$ROOT/scripts/codex-task-client.py"
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

contains_compact() {
  local file="$1" literal="$2"
  tr '\n' ' ' < "$file" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$literal"
}

not_contains() {
  local file="$1" literal="$2"
  ! grep -Fq -- "$literal" "$file"
}

regex() {
  local file="$1" expression="$2"
  grep -Eq -- "$expression" "$file"
}

check "Codex manifest is version 0.4.2" \
  json_field_is "$MANIFEST" version 0.4.2
check "Claude manifest is version 0.4.2" \
  json_field_is "$CLAUDE_MANIFEST" version 0.4.2
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
check "external planning defaults to nonblocking least-scope auto mode" \
  contains "$SKILL" '`auto-least-scope` (default)'
check "auto disclosure notice is explicitly not an approval gate" \
  contains_compact "$SKILL" 'The notice is not an approval gate'
check "auto mode forbids a confirmation question" \
  contains_compact "$SKILL" 'do not ask a confirmation question'
check "auto mode permits task-relevant private implementation inputs" \
  contains_compact "$SKILL" 'task-relevant private source code, build/release configuration, and tests'
check "external planning excludes secrets and customer data" \
  contains_compact "$SKILL" 'OAuth values, credentials, tokens, personal or customer data'
check "external planning excludes ignored corpora and unrelated files" \
  contains "$SKILL" 'ignored/private corpora, and unrelated files'
check "user can explicitly require an upfront approval pause" \
  contains "$SKILL" '`approval-required`'
check "user can explicitly disable external planning" \
  contains "$SKILL" '`no-external`'
check "broader external disclosure still needs separate authorization" \
  contains_compact "$SKILL" 'materially broader data category, destination, or purpose requires separate authorization'
check "allowed disclosure is never reauthorized mid-mission" \
  contains "$SKILL" 'Never re-ask for already-authorized least-scope inputs mid-mission'
check "Codex skill launches the shared Hybrid worker" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/spawn-worker.sh'
check "Hybrid launcher requires coordinator-owned control state" \
  contains "$SKILL" '--control-dir $HUB/control/<mission-slug>'
check "Codex skill provisions the executor brief" \
  contains "$SKILL" '$PLUGIN_DIR/templates/brief-exec.md'
check "Codex skill provisions the Fable brainstorm/plan brief" \
  contains "$SKILL" '$PLUGIN_DIR/templates/brief-codex.md'
check "Codex skill installs mission hooks without masking shared settings" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/install-worker-settings.sh'
check "worker settings installer exists and is executable" \
  test -x "$INSTALLER"
check "Codex skill uses Claude local project settings" \
  contains "$SKILL" '.claude/settings.local.json'
check "Codex skill no longer rejects tracked shared settings" \
  not_contains "$SKILL" 'If it already tracks `.claude/settings.json`'
check "Codex skill enforces the planned human go gate" \
  contains "$SKILL" 'state=planned'
check "Codex skill sends execution to the Codex stage" \
  contains "$SKILL" '--stage exec'
check "Codex skill resumes review on the Fable stage" \
  contains "$SKILL" '--stage review'
check "Codex skill bounces findings through rework" \
  contains "$SKILL" 'state=rework'
check "Codex acceptance cleanup automatically deletes completed leftovers" \
  contains "$SKILL" 'orchestrator-gc.sh --hub $HUB --clean'
check "Codex acceptance cleanup is limited to mission-owned origin refs" \
  contains "$SKILL" 'matching mission-owned `origin/orc/*` ref'
check "Codex acceptance cleanup records but never deletes the target branch" \
  contains "$SKILL" 'target branch is containment authority only: never delete or edit it'
check "Codex skill limits non-converging rework" \
  regex "$SKILL" '3rd rework|three.*rework'
check "Codex skill documents legacy 0.2 compatibility" \
  contains "$SKILL" 'Legacy Codex 0.2 compatibility'
check "Pending legacy missions are detected without session history" \
  contains "$SKILL" 'no Hybrid pipeline marker'
check "Hybrid 0.3 missions have an explicit in-flight compatibility classifier" \
  contains "$SKILL" 'Hybrid 0.3 single-executor compatibility'
check "Hybrid 0.3 classification requires missing DAG and task registry authority" \
  contains "$SKILL" 'approved-task-dag.json and the coordinator task registry are both absent'
check "Hybrid 0.3 execution resumes the recorded single Codex thread" \
  contains "$SKILL" 'resume the recorded `codex_thread_id` through the shared Hybrid launcher'
check "Hybrid 0.3 recovery never creates child tasks" \
  contains "$SKILL" 'never create child tasks for that in-flight mission'
check "Go gate snapshots the approved contract outside worker roots" \
  contains "$SKILL" 'approved-design.md'
check "Go gate executes exact task DAG freeze before child scheduling" \
  contains "$SKILL" 'validate-task-dag.sh --freeze'
check "native runtime requires the production lifecycle gate" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/task-worktree.sh'
check "native runtime requires the production integration gate" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/integrate-task.sh'
check "native runtime requires the DAG validator" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/validate-task-dag.sh'
check "native runtime requires the visible App Server task client" \
  contains "$SKILL" '$PLUGIN_DIR/scripts/codex-task-client.py create'
check "native child protocol invokes explicit classified create mode" \
  contains "$SKILL" '--create-mode native-0.4'
check "native child protocol passes the exact mission authority" \
  contains "$SKILL" '--mission-dir <exact-mission-dir>'
check "native child protocol requires production create before thread creation" \
  contains "$SKILL" 'must succeed before rendering or creating the Codex child thread'
check "legacy child compatibility remains an explicit classified path" \
  contains "$SKILL" '--create-mode legacy'
check "production native lifecycle assets are executable" bash -c \
  '[[ -x "$1" && -x "$2" && -x "$3" && -x "$4" ]]' _ \
  "$LIFECYCLE" "$INTEGRATE" "$VALIDATOR" "$TASK_CLIENT"
check "shared lifecycle lock mutations require the atomic directory guard" \
  contains "$SKILL" 'serialized through the same short-lived atomic guard directory'

check "shared launcher defaults to Fable-5 high" \
  contains "$SPAWN" 'WORKER_FLAGS=(--model "${ORC_PLAN_MODEL:-claude-fable-5}" --effort high'
check "plan model is overridable only through the sanctioned variable" \
  contains "$SPAWN" 'ORC_PLAN_MODEL:-claude-fable-5'
check "quota detection covers reached-limit wording, not just hit-limit" \
  contains "$SPAWN" "you've (hit|reached) your"
check "Claude skill mandates automatic quota fallback to Opus" \
  contains "$CLAUDE_SKILL" 'ORC_PLAN_MODEL=claude-opus-5'
check "Claude coordinator classifies native 0.4 before mission reconciliation" \
  contains "$CLAUDE_SKILL" 'classify-mission-version.sh'
check "Claude coordinator never mutates native 0.4 mission state" \
  contains "$CLAUDE_SKILL" 'do not mutate, resume, spawn,'
check "Claude coordinator hands native 0.4 back to Codex" \
  contains "$CLAUDE_SKILL" 'resume it from a Codex'
check "Claude coordinator durably marks new 0.3 missions before launch" \
  contains "$CLAUDE_SKILL" 'pipeline-version` containing the single line `0.3.0`'
check "Codex skill mandates automatic quota fallback to Opus" \
  contains "$SKILL" 'ORC_PLAN_MODEL=claude-opus-5'
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
check "shared launcher verifies coordinator-owned worker settings hash" \
  contains "$SPAWN" 'worker-settings.sha256'
check "executor reads the immutable approved brief" \
  contains "$SPAWN" '< "$CONTROL_DIR/brief-exec.md"'
check "executor is forbidden from touching planted local settings" \
  contains "$ROOT/templates/brief-exec.md" '.claude/settings.local.json'
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

check "README declares Orchestrator 0.4.2" \
  contains "$README" 'Orchestrator 0.4.2'
check "README scopes native 0.4 execution to the Codex coordinator" \
  contains "$README" 'Native 0.4 task-DAG execution is Codex-coordinator-only'
check "README documents fail-closed Claude handoff for native 0.4" \
  contains "$README" 'recognizes native 0.4 authority, makes no mission mutation'
check "README documents the explicit Claude 0.3 recovery marker" \
  contains "$README" 'explicit `0.3.0` pipeline marker before provisioning'
check "README documents App Server visible native child tasks" \
  contains "$README" 'App Server-backed project task windows'
check "README requires active task-list visibility for native children" \
  contains "$README" '`list_threads` visibility'
check "README forbids native hidden exec fallback" \
  contains "$README" 'Native 0.4 never falls back to `codex exec`'
check "README preserves codex exec only for Hybrid 0.3 compatibility" \
  contains "$README" 'Hybrid 0.3 compatibility continues to use `codex exec`'
check "README labels legacy Codex assets" \
  contains "$README" 'Legacy Codex 0.2 compatibility'

echo "  codex-hybrid-plugin: $OK/$N"
[[ "$OK" -eq "$N" ]]
