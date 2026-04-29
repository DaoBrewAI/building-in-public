# 10x-Engineer Plugin Integration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use 10x-engineer:executing-plans to implement this plan task-by-task.

**Goal:** Add the 10x-engineer plugin to the building-in-public repo as a DaoBrew-branded engineering workflow toolkit.

**Architecture:** Copy the full plugin structure from `~/.claude/plugins/local/10x-engineer/` into a `10x-engineer/` folder at the repo root. Rebrand plugin.json, add auto-execute to writing-plans, create guide-style README, and update the top-level README with a Plugins section.

**Tech Stack:** Markdown, JSON, shell script (all static files, no build system)

---

## Task Dependencies

Tasks in the same parallel group can be worked on concurrently.
Tasks with dependencies must wait for their prerequisites.

| Task | Parallel Group | Depends On | Files Touched |
|------|---------------|------------|---------------|
| 1: Copy plugin files | A | -- | `10x-engineer/**` (all 18 files) |
| 2: Rebrand plugin.json | B | Task 1 | `10x-engineer/.claude-plugin/plugin.json` |
| 3: Auto-execute option | B | Task 1 | `10x-engineer/skills/writing-plans/SKILL.md` |
| 4: Plugin README | B | Task 1 | `10x-engineer/README.md` |
| 5: Top-level README | B | Task 1 | `README.md` |
| 6: Commit all changes | C | Tasks 2-5 | -- |

**Parallel execution:** Tasks 2, 3, 4, and 5 (Group B) can run simultaneously after Task 1 completes.

---

### Task 1: Copy Plugin Files
**Parallel group:** A

**Files:**
- Create: `10x-engineer/` directory structure with all 18 source files

**Step 1: Create directory structure**

```bash
mkdir -p 10x-engineer/.claude-plugin
mkdir -p 10x-engineer/agents
mkdir -p 10x-engineer/commands
mkdir -p 10x-engineer/hooks
mkdir -p 10x-engineer/skills/brainstorming
mkdir -p 10x-engineer/skills/dispatching-parallel-agents
mkdir -p 10x-engineer/skills/executing-plans
mkdir -p 10x-engineer/skills/finishing-a-development-branch
mkdir -p 10x-engineer/skills/receiving-code-review
mkdir -p 10x-engineer/skills/requesting-code-review
mkdir -p 10x-engineer/skills/subagent-driven-development
mkdir -p 10x-engineer/skills/systematic-debugging
mkdir -p 10x-engineer/skills/test-driven-development
mkdir -p 10x-engineer/skills/using-superpowers
mkdir -p 10x-engineer/skills/verification-before-completion
mkdir -p 10x-engineer/skills/writing-plans
```

**Step 2: Copy all files**

```bash
SRC=~/.claude/plugins/local/10x-engineer
DEST=10x-engineer

cp "$SRC/.claude-plugin/plugin.json" "$DEST/.claude-plugin/plugin.json"
cp "$SRC/agents/code-reviewer.md" "$DEST/agents/code-reviewer.md"
cp "$SRC/commands/brainstorm.md" "$DEST/commands/brainstorm.md"
cp "$SRC/commands/execute-plan.md" "$DEST/commands/execute-plan.md"
cp "$SRC/commands/write-plan.md" "$DEST/commands/write-plan.md"
cp "$SRC/hooks/session-start.sh" "$DEST/hooks/session-start.sh"
cp "$SRC/skills/brainstorming/SKILL.md" "$DEST/skills/brainstorming/SKILL.md"
cp "$SRC/skills/dispatching-parallel-agents/SKILL.md" "$DEST/skills/dispatching-parallel-agents/SKILL.md"
cp "$SRC/skills/executing-plans/SKILL.md" "$DEST/skills/executing-plans/SKILL.md"
cp "$SRC/skills/finishing-a-development-branch/SKILL.md" "$DEST/skills/finishing-a-development-branch/SKILL.md"
cp "$SRC/skills/receiving-code-review/SKILL.md" "$DEST/skills/receiving-code-review/SKILL.md"
cp "$SRC/skills/requesting-code-review/SKILL.md" "$DEST/skills/requesting-code-review/SKILL.md"
cp "$SRC/skills/requesting-code-review/code-reviewer.md" "$DEST/skills/requesting-code-review/code-reviewer.md"
cp "$SRC/skills/subagent-driven-development/SKILL.md" "$DEST/skills/subagent-driven-development/SKILL.md"
cp "$SRC/skills/subagent-driven-development/implementer-prompt.md" "$DEST/skills/subagent-driven-development/implementer-prompt.md"
cp "$SRC/skills/subagent-driven-development/spec-reviewer-prompt.md" "$DEST/skills/subagent-driven-development/spec-reviewer-prompt.md"
cp "$SRC/skills/subagent-driven-development/code-quality-reviewer-prompt.md" "$DEST/skills/subagent-driven-development/code-quality-reviewer-prompt.md"
cp "$SRC/skills/systematic-debugging/SKILL.md" "$DEST/skills/systematic-debugging/SKILL.md"
cp "$SRC/skills/test-driven-development/SKILL.md" "$DEST/skills/test-driven-development/SKILL.md"
cp "$SRC/skills/using-superpowers/SKILL.md" "$DEST/skills/using-superpowers/SKILL.md"
cp "$SRC/skills/verification-before-completion/SKILL.md" "$DEST/skills/verification-before-completion/SKILL.md"
cp "$SRC/skills/writing-plans/SKILL.md" "$DEST/skills/writing-plans/SKILL.md"
```

**Step 3: Verify copy**

```bash
find 10x-engineer -type f | wc -l
```

Expected: 22 files (18 original + will become 22 after Tasks 2-4 modify/create)
At this point: 21 files (18 copied, plugin.json counts as 1)

Actually expected: 21 files (all source files copied)

---

### Task 2: Rebrand plugin.json
**Parallel group:** B

**Files:**
- Modify: `10x-engineer/.claude-plugin/plugin.json`

**Step 1: Replace plugin.json with rebranded version**

Write this exact content to `10x-engineer/.claude-plugin/plugin.json`:

```json
{
  "name": "10x-engineer",
  "version": "1.0.0",
  "description": "DaoBrew's curated engineering workflow toolkit for Claude Code — brainstorming, planning, TDD, systematic debugging, subagent-driven development, code review, and verification skills for autonomous multi-hour development sessions.",
  "repository": "https://github.com/DaoBrewAI/building-in-public",
  "license": "MIT",
  "keywords": [
    "10x-engineer",
    "workflow",
    "brainstorming",
    "planning",
    "tdd",
    "test-driven-development",
    "debugging",
    "systematic-debugging",
    "subagent",
    "code-review",
    "daobrew"
  ],
  "skills": [
    "./skills/"
  ],
  "commands": [
    "./commands/"
  ],
  "agents": [
    "./agents/code-reviewer.md"
  ],
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
          }
        ]
      }
    ]
  },
  "author": {
    "name": "DaoBrew AI",
    "url": "https://github.com/DaoBrewAI"
  },
  "credits": {
    "based_on": "obra/superpowers by Jesse Vincent",
    "source": "https://github.com/obra/superpowers"
  }
}
```

---

### Task 3: Add Auto-Execute Option to Writing Plans
**Parallel group:** B

**Files:**
- Modify: `10x-engineer/skills/writing-plans/SKILL.md`

**Step 1: Add auto-execute question after the announcement line**

In `10x-engineer/skills/writing-plans/SKILL.md`, find:

```
**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."
```

Replace with:

```
**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

## Execution Preference (Ask First)

**Before writing the plan, ask the user:**

```
Before I start, would you like to:

1. Review the plan before execution (I'll pause for your feedback)
2. Auto-execute when the plan is ready (I'll start implementing immediately)

Which do you prefer?
```

**If user chooses Review (Option 1):** Proceed normally. After saving the plan, present the Execution Handoff options and wait for feedback.

**If user chooses Auto-execute (Option 2):** Immediately ask which execution approach:

```
Auto-execute selected. Which execution approach?

1. Subagent-Driven (this session, sequential)
2. Team-Driven (this session, parallel)
3. Parallel Session (separate)
```

Remember both choices. After saving the plan, skip the review pause and immediately invoke the chosen execution skill.
```

---

### Task 4: Create Plugin README
**Parallel group:** B

**Files:**
- Create: `10x-engineer/README.md`

**Step 1: Write the guide-style README**

Create `10x-engineer/README.md` with this exact content:

```markdown
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
```

---

### Task 5: Update Top-Level README
**Parallel group:** B

**Files:**
- Modify: `README.md` (repo root)

**Step 1: Add Plugins section**

In `README.md`, find the line:

```
<!-- Add new skills above this line. Format: | emoji [**name**](./folder) | one-line description | -->
```

After that line and its following `---`, insert:

```markdown

## 🔌 Plugins

Plugins are multi-skill systems — install the whole folder for the full workflow, or cherry-pick individual skills. See each plugin's README for details.

| Plugin | What it does |
| :--- | :--- |
| 🧠 &nbsp;[**10x-engineer**](./10x-engineer) | A complete engineering workflow toolkit — brainstorming, planning, TDD, debugging, code review, and subagent-driven development. Twelve skills that chain together to take you from idea to merged PR. |

<!-- Add new plugins above this line. Format: | emoji [**name**](./folder) | one-line description | -->

---
```

---

### Task 6: Commit All Changes
**Parallel group:** C

**Step 1: Stage and commit**

```bash
git add 10x-engineer/ README.md
git commit -m "Add 10x-engineer plugin: DaoBrew's engineering workflow toolkit"
```
