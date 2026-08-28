#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing $1"; }
assert_json() { jq -e . "$1" >/dev/null || fail "invalid JSON: $1"; }

for manifest in \
  10x-engineer/.codex-plugin/plugin.json \
  orchestrator/.codex-plugin/plugin.json \
  orchestrator/.claude-plugin/plugin.json \
  .agents/plugins/marketplace.json \
  .claude-plugin/marketplace.json; do
  assert_file "$manifest"
  assert_json "$manifest"
done

[[ "$(jq -r .version 10x-engineer/.codex-plugin/plugin.json)" == 1.1.0 ]] ||
  fail "10x-engineer Codex version must be 1.1.0"
[[ "$(jq -r .version orchestrator/.codex-plugin/plugin.json)" =~ ^0\.5\.0\+codex\.[A-Za-z0-9._-]+$ ]] ||
  fail "orchestrator Codex version must be a cache-busted 0.5.0 release"
[[ "$(jq -r .version orchestrator/.claude-plugin/plugin.json)" == 0.5.0 ]] ||
  fail "orchestrator Claude version must be 0.5.0"
[[ "$(jq -r .skills orchestrator/.codex-plugin/plugin.json)" == ./skills/ ]] ||
  fail "orchestrator Codex manifest must use the shared native skill tree"
[[ "$(jq -r '.skills | join(" ")' orchestrator/.claude-plugin/plugin.json)" == ./skills/ ]] ||
  fail "orchestrator Claude manifest must use the shared native skill tree"

for skill in orchestrator/skills/*/SKILL.md; do
  assert_file "$(dirname "$skill")/agents/openai.yaml"
done

for removed in orchestrator/codex-scripts orchestrator/codex-templates orchestrator/codex-tests orchestrator/claude-skills; do
  [[ ! -d "$removed" || -z "$(find "$removed" -type f -print -quit)" ]] ||
    fail "retired compatibility tree still contains files: $removed"
done

assert_file orchestrator/scripts/spawn-worker.sh
assert_file orchestrator/scripts/codex-task-client.py
assert_file orchestrator/scripts/commit-broker.sh
assert_file orchestrator/skills/orchestrating/references/task-execution.md
assert_file orchestrator/skills/orchestrating/references/cleanup-and-rework.md
assert_file orchestrator/skills/orchestrating/references/continuation.md

rg -q 'claude-fable-5' orchestrator/scripts/spawn-worker.sh ||
  fail "Fable launcher does not pin Fable-5"
rg -q 'GPT-5.6-Sol' orchestrator/skills/orchestrating/SKILL.md ||
  fail "shared native skill does not pin GPT-5.6-Sol ownership"
! rg -q -- '--stage exec|codex_thread_id|codex exec' orchestrator/scripts/spawn-worker.sh ||
  fail "hidden single-executor path remains in Fable launcher"
rg -q 'thread/list' orchestrator/scripts/codex-task-client.py &&
  rg -q 'thread/read' orchestrator/scripts/codex-task-client.py &&
  rg -q 'project/list' orchestrator/scripts/codex-task-client.py &&
  rg -q 'project/create' orchestrator/scripts/codex-task-client.py &&
  rg -q 'thread/archive' orchestrator/scripts/codex-task-client.py &&
  rg -q 'thread/unarchive' orchestrator/scripts/codex-task-client.py &&
  rg -q 'turn/interrupt' orchestrator/scripts/codex-task-client.py ||
  fail "Claude-host App Server lifecycle bridge is incomplete"

for marketplace in .agents/plugins/marketplace.json .claude-plugin/marketplace.json; do
  jq -e '.plugins[] | select(.name == "orchestrator")' "$marketplace" >/dev/null ||
    fail "orchestrator missing from $marketplace"
done

bash orchestrator/tests/run.sh
echo "PASS shared native Orchestrator adoption contract"
