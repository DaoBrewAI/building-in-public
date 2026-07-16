# 10x Engineer

DaoBrew's disciplined engineering workflow toolkit for both Codex and Claude
Code. Version 1.1.0 contains 15 skills covering design, planning, TDD,
root-cause debugging, agent-driven execution, review, verification,
evidence-backed status, and understanding transfer.

## Codex installation

```bash
codex plugin marketplace add DaoBrewAI/building-in-public --ref main
codex plugin add 10x-engineer@building-in-public
```

Start a new Codex task after installation. The Codex manifest loads
`skills/`, whose instructions use Codex plan, collaboration,
visualization, and review surfaces.

Example prompts:

```text
Use $brainstorming to shape this feature before coding.
Use $writing-plans to turn this design into a TDD plan.
Use $verification-before-completion before claiming the branch is ready.
```

## Claude Code installation

The original Claude package remains in `claude-skills/`, `commands/`, `agents/`, and
`hooks/` and is still described by `.claude-plugin/plugin.json`.

```bash
cp -R 10x-engineer ~/.claude/plugins/local/10x-engineer
```

## Workflow

```text
Idea → Brainstorm → Plan → Execute ─┐
                                    ├→ TDD ↔ Debugging
                                    ├→ Spec + quality review
                                    ├→ Verification + status truth
                                    └→ Finish branch → change walkthrough
```

| Phase | Skills |
|---|---|
| Design | `brainstorming`, `writing-plans` |
| Execution | `executing-plans`, `subagent-driven-development`, `dispatching-parallel-agents` |
| Quality | `test-driven-development`, `systematic-debugging`, `verification-before-completion` |
| Review | `requesting-code-review`, `receiving-code-review` |
| Completion | `finishing-a-development-branch`, `status-truth`, `change-walkthrough` |
| Utilities | `bump-version`, `using-superpowers` |

The invariant across both hosts is evidence before claims: tests and checks must
be run in the current context, review findings must be resolved or rebutted with
technical proof, and outward-facing status must distinguish code state from
live evidence.

## Host-specific layout

| Path | Host | Purpose |
|---|---|---|
| `.codex-plugin/plugin.json` | Codex | Loads canonical `skills/` and install metadata |
| `skills/` | Codex | Codex-native workflows and `agents/openai.yaml` metadata |
| `.claude-plugin/plugin.json` | Claude Code | Loads original skills, commands, agent, and hook |
| `claude-skills/`, `commands/`, `agents/`, `hooks/` | Claude Code | Original v1.1.0 package |

## Credits

Originally based on [obra/superpowers](https://github.com/obra/superpowers) by
Jesse Vincent and adapted by [DaoBrew AI](https://github.com/DaoBrewAI).
