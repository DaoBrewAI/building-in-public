---
name: subagent-driven-development
description: Use when executing implementation plans with independent tasks in the current session
---

# Subagent-Driven Development

Execute plan by dispatching fresh subagent per task, with two-stage review after each: spec compliance review first, then code quality review.

**Core principle:** Fresh subagent per task + two-stage review (spec then quality) = high quality, fast iteration

## Teams Availability Check

Before starting execution, check if the Teams feature is available. Teams enables a **pipelined mode** where multiple implementers work concurrently while a dedicated reviewer handles completed work.

**How to check:** Attempt to use `TeamCreate`. If it's not in your available tools, fall back to Sequential Mode.

## Sequential Mode (Original / Fallback)

Use when Teams isn't available, tasks are tightly coupled, or you have only 1-2 tasks.

### The Process

1. Read plan, extract all tasks with full text, note context, create TodoWrite
2. For each task:
   - Dispatch implementer subagent (./implementer-prompt.md)
   - If implementer asks questions -> answer, provide context, re-dispatch
   - Implementer implements, tests, commits, self-reviews
   - Dispatch spec reviewer subagent (./spec-reviewer-prompt.md)
   - If spec review fails -> implementer fixes, re-review
   - Dispatch code quality reviewer subagent (./code-quality-reviewer-prompt.md)
   - If quality review fails -> implementer fixes, re-review
   - Mark task complete in TodoWrite
3. After all tasks: Dispatch final code reviewer for entire implementation
4. Use 10x-engineer:finishing-a-development-branch

## Team-Pipelined Mode (3+ Parallelizable Tasks)

When Teams is available and the plan has 3+ tasks that can be worked on concurrently, use pipelined execution: multiple implementer teammates work in parallel while you coordinate reviews.

### Architecture

```
+---------------------------------------------+
|            You (Team Lead)                   |
|  - Creates team + task list from plan        |
|  - Assigns tasks via TaskUpdate              |
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

```
1. TeamCreate(team_name="implement-feature", description="Execute plan: [feature name]")

2. For each task in plan:
   TaskCreate(
     subject="Task N: [name]",
     description="[FULL task text from plan, not a reference]",
     activeForm="Implementing [name]"
   )

3. Set dependencies from plan:
   TaskUpdate(taskId="4", addBlockedBy=["1", "2"])  // Task 4 needs 1 and 2 done first

4. Spawn implementer teammates (one per parallelizable task, max 4):
   Task(name="implementer-1", team_name="implement-feature", subagent_type="general-purpose",
        prompt="[Use ./implementer-prompt.md template with team additions]")
   Task(name="implementer-2", ...)
```

### Team Lead Review Workflow

As team lead, when a teammate reports completion:

1. **Spec review** -- Dispatch a spec reviewer subagent (./spec-reviewer-prompt.md) for the completed task
2. **If spec fails** -- `SendMessage` the implementer teammate with specific issues to fix
3. **If spec passes** -- Dispatch code quality reviewer (./code-quality-reviewer-prompt.md)
4. **If quality fails** -- `SendMessage` the implementer with issues
5. **If quality passes** -- Task is truly done. Check if any blocked tasks are now unblocked.

This pipelines the work: while you review Task 1, implementers are working on Tasks 2 and 3.

### Shutdown

When all tasks are reviewed and approved:
```
SendMessage(type="shutdown_request", recipient="implementer-1", content="All tasks complete")
// ... for each teammate
// After all acknowledge:
TeamDelete()
```

Then proceed to: **10x-engineer:finishing-a-development-branch**

## Prompt Templates

- `./implementer-prompt.md` - Dispatch implementer subagent
- `./spec-reviewer-prompt.md` - Dispatch spec compliance reviewer subagent
- `./code-quality-reviewer-prompt.md` - Dispatch code quality reviewer subagent

## Red Flags

**Never (both modes):**
- Skip reviews (spec compliance OR code quality)
- Proceed with unfixed issues
- Make subagent read plan file (provide full text instead)
- Skip scene-setting context
- Accept "close enough" on spec compliance
- **Start code quality review before spec compliance passes**

**Sequential mode only:**
- Dispatch multiple implementation subagents in parallel (use Team-Pipelined instead)

**Team-Pipelined mode only:**
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
