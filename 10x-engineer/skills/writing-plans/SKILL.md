---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

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

**Save plans to:** `docs/plans/` in the current working directory as `YYYY-MM-DD-<feature-name>.md`

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use 10x-engineer:executing-plans to implement this plan task-by-task.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

```markdown
### Task N: [Component Name]
**Parallel group:** [A/B/C/none] (see Task Dependencies below)

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**Step 2: Run test to verify it fails**

Run the project's test command (e.g. `pytest`, `npm test`, `swift test`, `go test ./...`)

Expected: FAIL with "function not defined"

**Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

**Step 4: Run test to verify it passes**

Run the project's test command.

Expected: PASS

**Step 5: Commit**

```bash
git commit -m "feat: add specific feature"
```
```

## Task Dependencies

**Every plan with 3+ tasks MUST include a dependency section** after the header:

```markdown
## Task Dependencies

Tasks in the same parallel group can be worked on concurrently.
Tasks with dependencies must wait for their prerequisites.

| Task | Parallel Group | Depends On | Files Touched |
|------|---------------|------------|---------------|
| 1: Database schema | A | -- | `db/migrations/001.sql` |
| 2: API endpoint | B | Task 1 | `src/api/users.py` |
| 3: UI component | B | Task 1 | `src/components/UserForm.js` |
| 4: Integration test | C | Tasks 2, 3 | `tests/integration/user_flow.py` |

**Parallel execution:** Tasks 2 and 3 (Group B) can run simultaneously after Task 1 completes.
```

**Rules for dependency modeling:**
- **Files Touched column is mandatory** -- prevents assigning two agents to the same file
- If two tasks touch the same file, they CANNOT be in the same parallel group
- Tasks with no dependencies get group "A" (first wave)
- Use letters for groups: A runs first, B after A completes, C after B, etc.
- Within a group, all tasks are independent and parallelizable
- If a task depends on a specific task (not a whole group), note it explicitly

## Remember
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits
- Include dependency table for plans with 3+ tasks

## Execution Handoff

After saving the plan, offer execution choice:

**"Plan complete and saved to `docs/plans/<filename>.md`. Three execution options:**

**1. Subagent-Driven (this session, sequential)** - I dispatch fresh subagent per task sequentially, review between tasks, fast iteration

**2. Team-Driven (this session, parallel)** - I create a team with multiple implementer teammates working concurrently on independent tasks, with pipelined reviews. *Requires TeamCreate tool availability.*

**3. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use 10x-engineer:subagent-driven-development (Sequential Mode)
- Stay in this session
- Fresh subagent per task + code review

**If Team-Driven chosen:**
- First check if `TeamCreate` tool is available
- If available: **REQUIRED SUB-SKILL:** Use 10x-engineer:subagent-driven-development (Team-Pipelined Mode)
- If NOT available: Inform user and fall back to Subagent-Driven (sequential)
- Use dependency table to set `addBlockedBy` relationships in TaskCreate
- Use "Files Touched" column to avoid assigning conflicting tasks to same teammate

**If Parallel Session chosen:**
- Guide them to open new session in worktree
- **REQUIRED SUB-SKILL:** New session uses 10x-engineer:executing-plans
