#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
MANIFEST="$ROOT/.codex-plugin/plugin.json"
CLASSIFIER="$ROOT/scripts/classify-mission-version.sh"
LIFECYCLE="$ROOT/scripts/task-worktree.sh"
SPAWN="$ROOT/scripts/spawn-worker.sh"
TASK_OUTCOME="$ROOT/scripts/task-outcome.py"
PLANNING_OUTPUT="$ROOT/scripts/planning-output.py"
NATIVE_HEALTH="$ROOT/scripts/native-task-health.py"
APPROVAL_HELPER="$ROOT/scripts/verify-approved-authority.py"
LIFECYCLE_LOCK="$ROOT/scripts/coordinator_lifecycle_lock.py"

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

check "manifest declares native-only cache-busted 0.5.4" bash -c \
  '[[ "$(jq -r .version "$1")" =~ ^0\.5\.4\+codex\.[A-Za-z0-9._-]+$ ]]' _ "$MANIFEST"

for removed in \
  "$ROOT/claude-skills" \
  "$ROOT/codex-scripts" \
  "$ROOT/codex-templates" \
  "$ROOT/codex-tests" \
  "$ROOT/IMPLEMENTATION-HANDOFF.md" \
  "$ROOT/IMPLEMENTATION-PLAN.md" \
  "$ROOT/implementation-notes.md" \
  "$ROOT/templates/brief.md"; do
  if [[ -d "$removed" ]]; then
    check "obsolete package tree contains no files: ${removed#$ROOT/}" bash -c \
      '[[ -z "$(find "$1" -type f -print -quit)" ]]' _ "$removed"
  else
    check "obsolete package asset removed: ${removed#$ROOT/}" test ! -e "$removed"
  fi
done

check "Claude marketplace advertises the native coordinator" bash -c \
  'jq -e '\''.plugins[] | select(.name == "orchestrator")'\'' "$1" >/dev/null' \
  _ "$REPO_ROOT/.claude-plugin/marketplace.json"
check "Codex marketplace still advertises Orchestrator" bash -c \
  'jq -e '\''.plugins[] | select(.name == "orchestrator")'\'' "$1" >/dev/null' \
  _ "$REPO_ROOT/.agents/plugins/marketplace.json"
check "Claude manifest shares the same native skill tree" bash -c \
  '[[ "$(jq -r .version "$1")" = 0.5.4 && "$(jq -r '\''.skills | join(" ")'\'' "$1")" = "./skills/" ]]' \
  _ "$ROOT/.claude-plugin/plugin.json"
check "Claude slash command routes to the shared native skill" grep -Fq \
  'orchestrator:orchestrating' "$ROOT/commands/orchestrate.md"

check "entry skill is at most 360 lines" bash -c \
  '[[ "$(wc -l < "$1" | tr -d " ")" -le 360 ]]' _ "$SKILL"
check "entry skill routes task execution details" grep -Fq \
  'references/task-execution.md' "$SKILL"
check "entry skill routes cleanup and rework details" grep -Fq \
  'references/cleanup-and-rework.md' "$SKILL"
check "entry skill routes continuation details" grep -Fq \
  'references/continuation.md' "$SKILL"

check "entry skill contains no legacy mission routing" bash -c \
  '! grep -Eqi '\''legacy (Codex )?0\.2|Hybrid 0\.3|single-executor compatibility|--create-mode legacy|codex exec fallback'\'' "$1"' \
  _ "$SKILL"
check "classifier accepts only native pipeline authority" bash -c \
  '! grep -Eqi '\''legacy-0\.2|hybrid-0\.3|0\.3\.0'\'' "$1" && grep -Fq '\''0.4.0'\'' "$1"' \
  _ "$CLASSIFIER"
check "task lifecycle has no legacy create mode" bash -c \
  '! grep -Eqi '\''create-mode.*legacy|verify_legacy_create|legacy create'\'' "$1"' \
  _ "$LIFECYCLE"
check "Fable launcher has no hidden Codex exec stage" bash -c \
  '! grep -Eqi '\''--stage exec|codex_thread_id|codex exec|commit-broker'\'' "$1"' \
  _ "$SPAWN"
check "coordinator task outcome helper is packaged" test -x "$TASK_OUTCOME"
check "shared frozen approval verifier is packaged" test -x "$APPROVAL_HELPER"
check "shared coordinator lifecycle lock is packaged" test -x "$LIFECYCLE_LOCK"
check "coordinator planning output importer is packaged" test -x "$PLANNING_OUTPUT"
check "coordinator native task health helper is packaged" test -x "$NATIVE_HEALTH"

for ref in planning-and-review.md task-execution.md cleanup-and-rework.md continuation.md; do
  check "required progressive-disclosure reference exists: $ref" \
    test -s "$ROOT/skills/orchestrating/references/$ref"
done

echo "  native-only-package-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
