# 10x-engineer

> DaoBrew's curated engineering workflow toolkit for Claude Code. Twelve skills that chain together to take you from idea to merged PR — with discipline baked in at every step.

---

## How It Works

The skills form a complete development workflow:

```
Idea → Brainstorm → Write Plan → Execute Plan ─┐
                                                 ├→ TDD ←→ Debugging
                                                 │    ↓
                                                 ├→ Code Review (spec + quality)
                                                 │    ↓
                                                 └→ Finish Branch → PR
```

**Brainstorming** refines your idea through Socratic dialogue into a concrete design. **Write Plan** turns that design into bite-sized, TDD-structured tasks with dependency tracking. **Execute Plan** runs those tasks — either sequentially with review checkpoints, or in parallel with multiple subagents.

During execution, every feature follows **Test-Driven Development** (write failing test → minimal code → refactor). When bugs surface, **Systematic Debugging** enforces root-cause investigation before any fix attempt. **Code Review** runs in two stages — spec compliance first, then code quality — after every task.

When all tasks pass, **Finish Branch** verifies tests one final time and presents structured options: draft PR, ready PR, keep as-is, or discard.

**Verification Before Completion** is the cross-cutting discipline: no success claims without fresh evidence. It applies everywhere.

---

## Installation

### Full Plugin (recommended)

Copy the `10x-engineer/` folder into your Claude Code plugins directory:

```bash
cp -r 10x-engineer/ ~/.claude/plugins/local/10x-engineer/
```

This installs all 12 skills, 3 commands, the code-reviewer agent, and the session-start hook. The hook automatically makes Claude check for applicable skills before every response.

### Individual Skills

Cherry-pick specific skills into your Claude Code skills directory:

```bash
# Example: just TDD and debugging
cp -r 10x-engineer/skills/test-driven-development/ ~/.claude/skills/test-driven-development/
cp -r 10x-engineer/skills/systematic-debugging/ ~/.claude/skills/systematic-debugging/
```

> **Note:** Some skills reference others. See the dependency column below to know which skills work standalone vs. which need companions.

---

## Skills

### Design Phase

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **brainstorming** | Socratic design refinement — explores requirements through one-question-at-a-time dialogue, proposes 2-3 approaches, presents design in validated sections | Standalone |
| **writing-plans** | Turns specs into detailed implementation plans with bite-sized TDD tasks, dependency graphs, and parallel execution groups | Standalone |

### Execution Phase

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **executing-plans** | Loads a plan and executes tasks in batches with review checkpoints between each batch | finishing-a-development-branch |
| **subagent-driven-development** | Dispatches fresh subagent per task with two-stage review (spec compliance + code quality) | requesting-code-review, finishing-a-development-branch |
| **dispatching-parallel-agents** | Splits independent problems across concurrent agents for parallel investigation | Standalone |

### Quality Phase

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **test-driven-development** | Enforces RED-GREEN-REFACTOR — no production code without a failing test first | Standalone |
| **systematic-debugging** | Four-phase root cause process: investigate → analyze patterns → hypothesize → implement fix | test-driven-development |
| **verification-before-completion** | No completion claims without fresh verification evidence — evidence before assertions, always | Standalone |

### Review Phase

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **requesting-code-review** | Dispatches code-reviewer subagent with structured review template | code-reviewer agent |
| **receiving-code-review** | Technical evaluation of review feedback — verify before implementing, push back when wrong | Standalone |

### Completion Phase

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **finishing-a-development-branch** | Verify tests → present 4 options (draft PR, ready PR, keep, discard) → execute choice | Standalone |

### Meta

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **using-superpowers** | Skill routing layer — makes Claude check for applicable skills before every response | Standalone (injected by session-start hook) |

---

## Commands

| Command | What it does |
| :--- | :--- |
| `/brainstorm` | Invoke the brainstorming skill |
| `/write-plan` | Invoke the writing-plans skill |
| `/execute-plan` | Invoke the executing-plans skill |

---

## Credits

Originally based on [obra/superpowers](https://github.com/obra/superpowers) by Jesse Vincent. MIT licensed.

Curated and adapted by [DaoBrew AI](https://github.com/DaoBrewAI).
