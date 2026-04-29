---
name: implement-phase
description: "Execute a phase plan task-by-task. Use when you have a generated phase plan and want to implement it with build verification after each task, parallel execution for independent tasks, and automatic deviation tracking."
user-invocable: true
argument-hint: "<phase_number> [from <plan_file_path>] [starting at task <task_number>]"
---

# /implement-phase — Execute a phase plan task-by-task

## Usage

```
/implement-phase <phase_number>
/implement-phase <phase_number> from <plan_file_path>
/implement-phase <phase_number> starting at task <task_number>
```

**Arguments:**
- `phase_number` — The phase to implement (e.g., `3`)
- `plan_file_path` (optional) — Explicit path to the plan file. If omitted, auto-discovers from `docs/plans/`
- `task_number` (optional) — Resume from a specific task (e.g., if tasks 1-3 are done, start at 4)

**Examples:**
```
/implement-phase 1
/implement-phase 3 from docs/plans/2026-03-09-phase3-avatar-screen.md
/implement-phase 2 starting at task 4
```

---

## Instructions

You are an implementation agent that executes phase plans step-by-step, following them precisely while adapting to real-world build results.

### Step 0: Invoke the executing-plans skill

**MANDATORY — do this FIRST before anything else.**

Use the Skill tool to invoke `10x-engineer:executing-plans`. This skill provides the disciplined task-by-task execution framework, review checkpoints, and deviation tracking that this command builds on. Follow its instructions alongside the steps below — when there is a conflict, this command's steps take precedence (since they add phase-specific logic like auto-discovery, pre-requisite checking, and parallel groups).

```
Skill: 10x-engineer:executing-plans
```

### Step 1: Locate the phase plan

**Auto-discovery** (no explicit path given):
1. List all files in `docs/plans/` matching the glob pattern `*-phase<N>-*` or `*-phase<N>.*` where `<N>` is the requested phase number
2. If exactly one match, use it
3. If multiple matches, present them to the user and ask which one
4. If no matches, tell the user: "No plan found for Phase N. Generate one with `/plan-phase N from <master-plan>`"

**Explicit path**: Use the provided file path directly.

### Step 2: Read and parse the plan

Read the plan file. Extract:
1. **Goal** — what this phase achieves (from the `**Goal:**` line)
2. **Project root** — the working directory (from the `**Project root:**` line)
3. **Task list** — all tasks with their:
   - Task number and name (from `## Task N: <Name>` headings)
   - Parallel group letter (from `**Parallel group:**`)
   - Dependencies (from the Task Dependencies table)
   - Files touched (from `**Files:**` sections)
   - All steps within each task
4. **Pre-requisites** — what prior phases must have delivered (from `## Pre-requisites from Previous Phases`)

### Step 3: Verify pre-requisites

Before implementing anything, check that pre-requisites from prior phases are met:

1. For each listed pre-requisite, verify the file/component actually exists in the codebase
2. If a pre-requisite is missing, check if the plan has a **fallback** listed
3. If fallbacks exist, tell the user and ask whether to proceed with fallbacks or stop
4. If no fallbacks and pre-requisites are missing, STOP and tell the user:
   ```
   Phase N requires outputs from Phase M that are not yet implemented:
   - <missing item>
   Run `/implement-phase M` first, or `/plan-status` to see the full picture.
   ```

### Step 4: Build the execution plan

Create a TodoWrite checklist from the task list. Each task becomes a todo item.

If the user specified `starting at task T`, mark tasks 1 through T-1 as `completed`.

Organize by parallel groups:
- Tasks in the same parallel group CAN be executed via parallel subagents (Agent tool)
- Tasks in later groups MUST wait for their dependencies

Example todo list:
```
[completed] Task 1: Update dark mode color palette (Group A)
[completed] Task 2: Add typography system (Group A)
[in_progress] Task 3: Add light/dark adaptive color support (Group B — depends on Task 1)
[pending] Task 4: Create Asset Catalog structure (Group A)
[pending] Task 5: Build verification (Group D — depends on all)
```

### Step 5: Execute tasks

For each task, follow this cycle:

#### 5a. Start the task
- Mark the task as `in_progress` in TodoWrite
- Announce: "Starting Task N: <name>"

#### 5b. Execute each step
Follow the steps in the plan **literally**:
- **"Read" steps** → Use the Read tool
- **"Create/Write" steps** → Use Write or Edit tools with the exact code from the plan
- **"Replace" steps** → Use Edit tool, matching the old_string precisely
- **"Build to verify" steps** → Run the build command via Bash
- **"Commit" steps** → Run the git commands via Bash

#### 5c. Handle build failures
When a build/verify step fails:
1. Read the full error output
2. Analyze whether the error is:
   - **Plan error** — the plan's code has a bug (e.g., typo, wrong API) → Fix it, document what you changed
   - **Environment error** — missing dependency, wrong path → Fix the environment issue
   - **Dependency error** — needs output from an unfinished task → Skip this task, move to the next independent task, come back later
3. Fix the error and re-run the build
4. If you can't fix it after 2 attempts, STOP the task and report:
   ```
   Task N blocked: <error description>
   Attempted fixes: <what you tried>
   Suggested resolution: <your best guess>
   ```

#### 5d. Commit the task
After the build succeeds:
- Run the commit command from the plan
- If the plan doesn't specify a commit message, generate one following conventional commit format

#### 5e. Complete the task
- Mark the task as `completed` in TodoWrite
- Announce: "Completed Task N: <name>"

### Step 6: Parallel execution (when possible)

When multiple tasks share the same parallel group AND touch different files:
- Use the Agent tool to launch parallel subagents, one per task
- Each subagent gets the full task instructions from the plan
- Wait for all subagents in the group to complete before moving to the next group

**When NOT to parallelize** (even if same group):
- Tasks touch the same file
- The project's build system doesn't support concurrent modifications
- The user asked for sequential execution

### Step 7: Final verification

After all tasks are complete:

1. Run the final build verification task (usually the last task in the plan)
2. Run `git log --oneline -N` (where N = number of tasks) to show the commit history
3. Present a summary:

```
## Phase N Implementation Complete

**Goal:** <goal from plan>

### Tasks completed:
- [x] Task 1: <name> — <commit hash>
- [x] Task 2: <name> — <commit hash>
- ...

### Build status: PASSING

### Deviations from plan:
- Task 3, Step 2: Changed X to Y because <reason>
- (none if no deviations)

### Next: Phase N+1
Run `/implement-phase <N+1>` or `/plan-status` to see what's next.
```

### Step 8: Update phase index (if exists)

If `docs/plans/PHASE-INDEX.md` exists, update the status of this phase from `Planned` to `Implemented`.

---

## Error recovery

If the session is interrupted mid-implementation:
- The user can resume with `/implement-phase N starting at task T`
- The TodoWrite state shows which tasks are done
- Each task is committed independently, so the repo is in a consistent state

## Important rules

1. **Follow the plan literally** — The plan was reviewed and approved. Execute it, don't redesign it.
2. **Document deviations** — If you must deviate from the plan (e.g., to fix a bug in the plan's code), note exactly what you changed and why.
3. **One commit per task** — Don't squash multiple tasks into one commit. Each task should be an atomic, reviewable unit.
4. **Build after every task** — Never skip the build verification step. A broken build blocks all subsequent tasks.
5. **Don't modify files outside the plan** — If you discover something that needs fixing outside the plan's scope, note it but don't fix it. The plan is the scope.
