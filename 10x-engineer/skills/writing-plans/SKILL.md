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

First inspect the invoking context. If it explicitly records both an execution
preference and an execution approach as already approved, honor those choices
without asking again. This is the non-interactive path for an orchestrated
worker that cannot talk to the end user. Record the inherited choices in the
plan. If the context also specifies **brokered commits**, replace each Commit
step with a **Commit checkpoint** that lists the files and proposed message;
do not run `git commit` because the trusted outer workflow owns Git metadata.

**Before writing the plan, ask the user:**

```
Before I start, would you like to:

1. Review the plan before execution (I'll pause for your feedback)
2. Auto-execute when the plan is ready (I'll start implementing immediately)

Which do you prefer?
```

**If user chooses Review (Option 1):** Proceed normally. After saving the plan, present the Review Companion (see below) together with the Execution Handoff options and wait for feedback.

**If user chooses Auto-execute (Option 2):** Immediately ask which execution approach:

```
Auto-execute selected. Which execution approach?

1. Subagent-Driven (this session, sequential)
2. Agent-Driven (this session, parallel)
3. Parallel Session (separate)
```

Remember both choices. After saving the plan, skip the review pause and immediately invoke the chosen execution skill.

**Save plans to:** `docs/plans/` in the current working directory as `YYYY-MM-DD-<feature-name>.md`

## Review Companion (HTML) — Required

Every plan produces TWO artifacts: the detailed markdown plan (what gets executed) and an HTML **review companion** (what the human reads before execution — review only).

After saving the detailed plan, generate the companion with the
`visualize:visualize` skill when available; otherwise save it to
`docs/plans/YYYY-MM-DD-<feature-name>-review.html` and tell the user to open it.

**Ordering rule — lead with what the human is most likely to tweak:**
1. **Data model changes** — schemas, tables, stored formats, state shapes
2. **New type interfaces / contracts** — public APIs, signatures, protocols, events
3. **Anything user-facing** — UI, CLI flags, messages, behavior changes
4. Bury **mechanical work** (refactors, wiring, test scaffolding) at the bottom in a compact/collapsed section labeled as trusted — the human doesn't need to review it.

For each leading item show: the decision made, 1–2 realistic alternatives, and a likely-tweak vs settled marker. Keep it a 2-minute scan, not a second copy of the plan.

The companion is REVIEW-ONLY: execution always follows the detailed markdown plan. If review feedback changes a decision, update the markdown plan first, then regenerate the companion.

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

> **For Codex:** REQUIRED SKILL: Use 10x-engineer:executing-plans to implement this plan task-by-task.

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
- **Change scope discipline** — Plans must not include changes to existing behavior unless absolutely necessary for the task. No drive-by refactors or cleanups.
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills by their exact catalog name or `$skill-name` invocation syntax.
- DRY, YAGNI, TDD, frequent commits (or frequent commit checkpoints when the
  invoking workflow explicitly uses brokered commits)
- Include dependency table for plans with 3+ tasks

## Execution Handoff

After saving the plan, offer execution choice:

**"Plan complete and saved to `docs/plans/<filename>.md`. Three execution options:**

**1. Subagent-Driven (this session, sequential)** - I dispatch fresh subagent per task sequentially, review between tasks, fast iteration

**2. Agent-Driven (this session, parallel)** - I spawn bounded implementer agents for independent tasks, with pipelined reviews. *Requires Codex collaboration tools.*

**3. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use 10x-engineer:subagent-driven-development (Sequential Mode)
- Stay in this session
- Fresh subagent per task + code review

**If Agent-Driven chosen:**
- First check whether `spawn_agent`, `send_message`, and `wait_agent` are available.
- If available: **REQUIRED SKILL:** Use 10x-engineer:subagent-driven-development (Agent-Pipelined Mode).
- If unavailable: inform the user and fall back to root-agent or sequential execution.
- Use the dependency table and `update_plan` to release only unblocked tasks.
- Use the "Files Touched" column to avoid assigning conflicting tasks concurrently.

**If Parallel Session chosen:**
- Guide them to open new session in worktree
- **REQUIRED SUB-SKILL:** New session uses 10x-engineer:executing-plans
