---
name: subagent-driven-development
description: Use when executing implementation plans with independent tasks in the current session
---

# Subagent-Driven Development

Execute plan by dispatching fresh subagent per task, with two-stage review after each: spec compliance review first, then code quality review.

**Core principle:** Fresh subagent per task + two-stage review (spec then quality) = high quality, fast iteration

## Collaboration Availability Check

Before starting execution, check whether Codex exposes collaboration tools such
as `spawn_agent`, `send_message`, and `wait_agent`. They enable a **pipelined
mode** where multiple implementers work concurrently while dedicated reviewers
inspect completed work.

**How to check:** Inspect the available tools. If agent spawning is unavailable,
fall back to root-agent execution with the same spec and quality review gates.

## Sequential Mode (Original / Fallback)

Use when collaboration tools are unavailable, tasks are tightly coupled, or you have only 1-2 tasks.

### The Process

1. Read the plan, extract every task with full text, note context, and mirror it in `update_plan`.
2. For each task:
   - Dispatch implementer subagent (./implementer-prompt.md)
   - If implementer asks questions -> answer, provide context, re-dispatch
   - Implementer implements, tests, commits, self-reviews. If the invoking
     context specifies brokered commits, it records a commit checkpoint and
     leaves the working tree uncommitted instead.
   - Dispatch spec reviewer subagent (./spec-reviewer-prompt.md)
   - If spec review fails -> implementer fixes, re-review
   - Dispatch code quality reviewer subagent (./code-quality-reviewer-prompt.md)
   - If quality review fails -> implementer fixes, re-review
   - Mark the task complete in `update_plan`.
3. After all tasks: Dispatch final code reviewer for entire implementation
4. Use 10x-engineer:finishing-a-development-branch

## Agent-Pipelined Mode (3+ Parallelizable Tasks)

When collaboration tools are available and the plan has 3+ tasks that can be
worked on concurrently, use pipelined execution: multiple bounded implementer
agents work in parallel while you coordinate reviews.

### Architecture

```
+---------------------------------------------+
|          You (Coordinator)                   |
|  - Creates team + task list from plan        |
|  - Owns the plan and file boundaries         |
|  - Reviews completed work (spec + quality)   |
|  - Sends feedback via SendMessage            |
|  - Shuts down team when all tasks pass       |
+------+----------+--------------+-------------+
       |          |              |
       v          v              v
+----------+ +----------+ +----------+
|implmtr-1 | |implmtr-2 | |implmtr-3 |
|(general) | |(general) | |(general) |
|Task 1    | |Task 2    | |Task 3    |
+----------+ +----------+ +----------+
```

### Setup

1. Parse the dependency table and place all tasks in `update_plan`.
2. Assign disjoint file ownership to every task in the same parallel group.
3. Call `spawn_agent` once for each currently unblocked task before waiting,
   up to the available concurrency limit. Include the full task text and the
   `./implementer-prompt.md` instructions in each prompt.
4. Record every returned agent id. Use `send_message` for course corrections,
   `followup_task` for another bounded turn, and `wait_agent` to collect results.

### Coordinator Review Workflow

As team lead, when a teammate reports completion:

1. **Spec review** -- Dispatch a spec reviewer subagent (./spec-reviewer-prompt.md) for the completed task
2. **If spec fails** -- use `send_message` or `followup_task` to give the implementer specific issues to fix
3. **If spec passes** -- Dispatch code quality reviewer (./code-quality-reviewer-prompt.md)
4. **If quality fails** -- send the implementer the concrete issues
5. **If quality passes** -- Task is truly done. Check if any blocked tasks are now unblocked.

This pipelines the work: while you review Task 1, implementers are working on Tasks 2 and 3.

### Shutdown

When all tasks are reviewed and approved, interrupt any still-running bounded
agent, collect final statuses with `list_agents`, and leave no orphaned work.

Then proceed to: **10x-engineer:finishing-a-development-branch**. In a
brokered-commit workflow, skip branch finishing and return the reviewed,
verified working tree to the outer orchestrator for its trusted commit step.

## Prompt Templates

- `./implementer-prompt.md` - Dispatch implementer subagent
- `./spec-reviewer-prompt.md` - Dispatch spec compliance reviewer subagent
- `./code-quality-reviewer-prompt.md` - Dispatch code quality reviewer subagent

## Red Flags

**Never (both modes):**
- **Change existing behavior unless absolutely necessary for the current task** — no drive-by refactors, no style cleanups, no "while I'm here" improvements
- Skip reviews (spec compliance OR code quality)
- Proceed with unfixed issues
- Make subagent read plan file (provide full text instead)
- Skip scene-setting context
- Accept "close enough" on spec compliance
- **Start code quality review before spec compliance passes**

**Sequential mode only:**
- Dispatch multiple implementation subagents in parallel (use Agent-Pipelined instead)

**Agent-Pipelined mode only:**
- Spawn more than 4-5 teammates (diminishing returns, coordination overhead)
- Let teammates work on tasks that edit the same files (conflict risk)
- Skip shutdown protocol (teammates keep running)
- Forget to check if blocked tasks unblock after completions

## Integration

**Required workflow skills:**
- **10x-engineer:writing-plans** - Creates the plan this skill executes
- **10x-engineer:requesting-code-review** - Code review template for reviewer subagents
- **10x-engineer:finishing-a-development-branch** - Complete development after all tasks

**Subagents should use:**
- **10x-engineer:test-driven-development** - Subagents follow TDD for each task

**Alternative workflow:**
- **10x-engineer:executing-plans** - Use for parallel session instead of same-session execution
