# Codex Adoption Design

## Goal

Publish Codex-native editions of the upstream `orchestrator` 0.2.0 and
`10x-engineer` 1.1.0 plugins without regressing their existing Claude Code
packages.

## Chosen architecture

Keep the Claude and Codex surfaces side by side. Existing `.claude-plugin/`,
`skills/`, `commands/`, hooks, scripts, and templates remain unchanged. Codex
manifests point at separate `codex-skills/` trees, and orchestrator-specific
runtime files live under `codex-scripts/`, `codex-templates/`, and
`codex-tests/`. This avoids conditional prose that is wrong in one host and
makes each package independently testable.

The Codex orchestrator launches one persistent `codex exec --json` thread per
mission. It uses `workspace-write`, explicit `--add-dir` roots, `approval=never`,
and trusted mission-local `.codex/hooks.json`; it does not bypass the sandbox.
The wrapper records its PID immediately and captures the Codex `thread_id` from
JSONL for later `codex exec resume`. Mission state, reports, and decisions stay
in the existing `.orchestrator/` disk protocol.

Codex does not offer a generic dormant-conversation process-exit callback.
Therefore the worker wrapper preserves macOS notifications and durable state,
while the coordinator polls an active terminal handle when available and always
reconciles mission state at the next invocation. This is an explicit platform
adaptation, not a silent promise of Claude-style wake behavior.

## Package and discovery model

- Add `.agents/plugins/marketplace.json` with Codex policy metadata.
- Update `10x-engineer/.codex-plugin/plugin.json` to version 1.1.0 and
  `./codex-skills/`.
- Add `orchestrator/.codex-plugin/plugin.json` at version 0.2.0.
- Add `agents/openai.yaml` to every Codex skill for install-surface metadata.
- Keep the legacy `.claude-plugin/marketplace.json` and all Claude sources.

## Validation

Repository tests will assert the Codex manifests and marketplace shape, reject
Claude-only runtime/tool vocabulary from Codex skill trees, exercise the Codex
worker guard and pipeline gate, validate plugin manifests, validate every skill,
and smoke-test the worker wrapper's argument/error handling without launching a
paid model run.
