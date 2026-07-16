#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

assert_json() {
  jq -e . "$1" >/dev/null || fail "invalid JSON: $1"
}

assert_file 10x-engineer/.codex-plugin/plugin.json
assert_file orchestrator/.codex-plugin/plugin.json
assert_file .agents/plugins/marketplace.json

assert_json 10x-engineer/.codex-plugin/plugin.json
assert_json orchestrator/.codex-plugin/plugin.json
assert_json .agents/plugins/marketplace.json

[[ "$(jq -r .version 10x-engineer/.codex-plugin/plugin.json)" == "1.1.0" ]] ||
  fail "10x-engineer Codex version must be 1.1.0"
[[ "$(jq -r .skills 10x-engineer/.codex-plugin/plugin.json)" == "./skills/" ]] ||
  fail "10x-engineer must use the canonical Codex skill tree"
[[ "$(jq -r .version orchestrator/.codex-plugin/plugin.json)" == "0.2.0" ]] ||
  fail "orchestrator Codex version must be 0.2.0"
[[ "$(jq -r .skills orchestrator/.codex-plugin/plugin.json)" == "./skills/" ]] ||
  fail "orchestrator must use the canonical Codex skill tree"

for plugin in 10x-engineer orchestrator; do
  expected="$(find "$plugin/claude-skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
  actual="$(find "$plugin/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
  [[ "$actual" == "$expected" ]] ||
    fail "$plugin Codex skill count $actual does not match upstream count $expected"

  while IFS= read -r skill; do
    assert_file "$(dirname "$skill")/agents/openai.yaml"
  done < <(find "$plugin/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
done

FORBIDDEN='Skill tool|Task tool|TodoWrite|TeamCreate|TaskCreate|TaskUpdate|AskUserQuestion|For Claude|Artifact tool|artifact-design|CLAUDE_PLUGIN_ROOT|claude -p|dangerously-skip-permissions|\.claude/'
if rg -n "$FORBIDDEN" 10x-engineer/skills orchestrator/skills; then
  fail "Claude-only runtime vocabulary remains in Codex-native skills"
fi

assert_file orchestrator/codex-scripts/spawn-worker.sh
assert_file orchestrator/codex-scripts/mission-commit.sh
assert_file orchestrator/codex-tests/run.sh

rg -q 'CODEX_BIN=.*codex' orchestrator/codex-scripts/spawn-worker.sh &&
  rg -q '"\$CODEX_BIN" exec' orchestrator/codex-scripts/spawn-worker.sh ||
  fail "worker launcher does not invoke the Codex exec subcommand"
rg -q -- '--sandbox workspace-write' orchestrator/codex-scripts/spawn-worker.sh ||
  fail "worker launcher does not use workspace-write sandbox"
rg -q -- '--ask-for-approval never' orchestrator/codex-scripts/spawn-worker.sh ||
  fail "worker launcher does not disable impossible non-interactive approvals"
rg -q 'sandbox_workspace_write.writable_roots=\[\]' orchestrator/codex-scripts/spawn-worker.sh &&
  rg -q 'sandbox_workspace_write.exclude_slash_tmp=true' orchestrator/codex-scripts/spawn-worker.sh &&
  rg -q 'sandbox_workspace_write.exclude_tmpdir_env_var=true' orchestrator/codex-scripts/spawn-worker.sh ||
  fail "worker launcher does not replace ambient writable roots and exclude implicit temp roots"
rg -q -- '--control-manifest' orchestrator/codex-scripts/spawn-worker.sh &&
  rg -q -- '--control-manifest' orchestrator/codex-scripts/mission-commit.sh ||
  fail "launcher and commit broker do not require coordinator-owned worktree authority"
if rg -n -- '--dangerously-bypass-hook-trust|dangerously-bypass-approvals-and-sandbox' orchestrator/codex-scripts; then
  fail "Codex orchestrator runtime broadens hook trust or disables the sandbox"
fi
if rg -n 'claude -p|dangerously-skip-permissions|\.claude/' orchestrator/codex-scripts orchestrator/codex-templates; then
  fail "Claude runtime remains in Codex orchestrator runtime"
fi

for name in 10x-engineer orchestrator; do
  jq -e --arg name "$name" '
    .plugins[]
    | select(.name == $name)
    | (.source.source == "local")
      and (.source.path | startswith("./"))
      and (.policy.installation == "AVAILABLE")
      and (.policy.authentication == "ON_INSTALL")
      and (.category == "Productivity")
  ' .agents/plugins/marketplace.json >/dev/null ||
    fail "marketplace entry for $name is missing required Codex metadata"
done

bash orchestrator/codex-tests/run.sh

echo "PASS Codex adoption contract"
