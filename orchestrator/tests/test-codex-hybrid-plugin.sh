#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_MANIFEST="$ROOT/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TASK_REF="$ROOT/skills/orchestrating/references/task-execution.md"
CLEANUP_REF="$ROOT/skills/orchestrating/references/cleanup-and-rework.md"
CONTINUATION_REF="$ROOT/skills/orchestrating/references/continuation.md"
README="$ROOT/README.md"
GC_SCRIPT="$ROOT/scripts/orchestrator-gc.sh"

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then OK=$((OK + 1)); else echo "  case $N failed: $label"; fi
}
contains() { grep -Fq -- "$2" "$1"; }
compact() { tr '\n' ' ' < "$1" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$2"; }

check "Codex manifest is the 0.5.0 cache-busted release" bash -c \
  '[[ "$(jq -r .version "$1")" =~ ^0\.5\.0\+codex\.[A-Za-z0-9._-]+$ ]]' _ "$CODEX_MANIFEST"
check "Claude manifest is 0.5.0" bash -c '[[ "$(jq -r .version "$1")" = 0.5.0 ]]' _ "$CLAUDE_MANIFEST"
check "both hosts share one skill tree" bash -c \
  '[[ "$(jq -r .skills "$1")" = ./skills/ && "$(jq -r '\''.skills | join(" ")'\'' "$2")" = ./skills/ ]]' \
  _ "$CODEX_MANIFEST" "$CLAUDE_MANIFEST"
check "Claude command routes to shared skill" contains "$ROOT/commands/orchestrate.md" 'orchestrator:orchestrating'

check "Fable owns brainstorm plan and review" compact "$SKILL" 'Fable-5 high owns brainstorm, design, plan, review, and re-review'
check "Codex owns implementation" compact "$SKILL" 'GPT-5.6-Sol high owns every implementation'
check "native child tasks are visible" contains "$SKILL" 'visible project-local Codex tasks'
check "hidden codex exec is forbidden" contains "$SKILL" 'never use hidden `codex exec` sessions'
check "external planning is nonblocking" contains "$SKILL" 'auto-least-scope'
check "secrets and customer data are excluded" compact "$SKILL" 'credentials, tokens, OAuth values, personal/customer data'
check "native authority is exact 0.4.0" compact "$SKILL" 'pipeline-version` containing exactly `0.4.0'
check "Phase 0 is report-only" contains "$SKILL" 'Run report-only discovery'
check "Phase 0 never uses hub-wide cleanup" contains "$SKILL" 'Never use hub-wide destructive cleanup here'
check "brainstorm clarification bridge remains" contains "$SKILL" 'kind: brainstorm-clarification'
check "founder go remains the only planned pause" contains "$SKILL" '`planned` is the only planned human pause'
check "review reuses Fable" contains "$SKILL" '--stage review'
check "blocked work uses mediation" contains "$SKILL" 'orchestrator:orchestrator-mediation'
check "acceptance marks terminal before GC" compact "$SKILL" 'Write mission state/phase `accepted`, then read the cleanup reference'

check "task reference defines ready-set integration" compact "$TASK_REF" 'every predecessor is durably `integrated` or `collected`'
check "task reference uses production lifecycle gate" contains "$TASK_REF" 'scripts/task-worktree.sh create'
check "task reference creates App Server child" contains "$TASK_REF" 'scripts/codex-task-client.py create'
check "task health requires list visibility" compact "$TASK_REF" 'requires App Server `thread/list` visibility and `thread/read` evidence'
check "Claude host has lifecycle bridge operations" compact "$TASK_REF" '`codex-task-client.py stop` plus `archive`'
check "all child windows inherit the parent project" compact "$TASK_REF" 'Every child must use the same `projectId` as its coordinator/parent session'
check "task outcomes remain durable" contains "$TASK_REF" 'Chat text is advisory'
check "integration preserves immutable histories" contains "$TASK_REF" 'never rebase, squash, amend, reset, or force'
check "individual integration retains visible child resources" compact "$TASK_REF" 'Do not run GC or archive a child after individual integration'
check "all integrated tasks trigger one automatic batch cleanup" compact "$SKILL" 'batch-collect every integrated child, archive every child window'
check "batch cleanup waits for every task integration" compact "$CLEANUP_REF" 'Batch child collection begins only after every approved task is completed and integrated into the parent'
check "batch cleanup archives windows only after all task resources collect" compact "$CLEANUP_REF" 'archive every accepted child window only after the batch collection'
check "batch readiness is proven while holding the lifecycle lock" python3 - "$GC_SCRIPT" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("scan_child_tasks() {")
block = text[start:text.index("\nscan_child_tasks\n", start)]
lock = block.index('if ! gc_acquire_lifecycle_lock "$control_phys"; then')
ready = block.index('if ! child_batch_cleanup_ready "$control_phys" "$mission"; then')
raise SystemExit(0 if lock < ready else 1)
PY

check "cleanup reference preserves exact child GC" contains "$CLEANUP_REF" 'exact-tip verification with a lease'
check "cleanup reference preserves task-window archival" contains "$CLEANUP_REF" 'archive the exact accepted child'
check "cleanup reference preserves same-thread rework" contains "$CLEANUP_REF" 'resume the same ID'
check "cleanup reference uses mission scope" contains "$CLEANUP_REF" '--mission <mission> --clean'
check "cleanup reference never deletes target" contains "$CLEANUP_REF" 'Never delete or edit the target branch'

check "continuation reference preserves immutable request" contains "$CONTINUATION_REF" 'request ID is the SHA-256'
check "continuation limits replacement" compact "$CONTINUATION_REF" 'allow at most one replacement'
check "continuation promotion prevents dual ownership" contains "$CONTINUATION_REF" 'without dual ownership'
check "README documents dual-host native package" compact "$README" 'Native Codex mission control with fixed backend ownership'

echo "  codex-hybrid-plugin: $OK/$N"
[[ "$OK" -eq "$N" ]]
