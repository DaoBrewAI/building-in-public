---
name: implement-project
description: "Execute all phases of a project sequentially with checkpoints between phases. Use when you want to implement an entire multi-phase project end-to-end, with user confirmation gates between phases and automatic progress tracking."
user-invocable: true
argument-hint: "[from <master_plan_path>] [starting at phase <phase_number>]"
---

# /implement-project — Execute all phases of a project sequentially

## Usage

```
/implement-project
/implement-project from <master_plan_path>
/implement-project starting at phase <phase_number>
```

**Arguments:**
- `master_plan_path` (optional) — Path to the master plan. If omitted, auto-discovers from `docs/plans/PHASE-INDEX.md` or by scanning for phase plan files.
- `phase_number` (optional) — Start from this phase (skips earlier ones). Default: starts at the first unimplemented phase.

**Examples:**
```
/implement-project
/implement-project from docs/plans/2026-03-08-figma-to-ios-integration-design.md
/implement-project starting at phase 3
```

---

## Instructions

You are a project orchestrator that executes an entire multi-phase project by implementing each phase plan in order.

### Step 0: Invoke the executing-plans skill

**MANDATORY — do this FIRST before anything else.**

Use the Skill tool to invoke `10x-engineer:executing-plans`. This skill provides the disciplined task-by-task execution framework, review checkpoints, and deviation tracking that all phase implementations use. It will be active throughout the entire project execution.

```
Skill: 10x-engineer:executing-plans
```

### Step 1: Discover all phase plans

Scan `docs/plans/` for all files matching the pattern `*-phase*-*.md`. Sort them by phase number.

Extract phase numbers from filenames using the pattern: `-phase<N>-` where N is one or more digits.

Build the phase roster:
```
Phase 1: docs/plans/2026-03-09-phase1-color-system-and-assets.md
Phase 2: docs/plans/2026-03-09-phase2-tab-bar-and-navigation.md
Phase 3: docs/plans/2026-03-09-phase3-avatar-screen.md
Phase 4: (no plan found)
...
```

If there are gaps (e.g., Phase 4 has no plan), STOP and tell the user:
```
Missing plan for Phase 4. Generate it first:
  /plan-phase 4 from <master-plan>
Or generate all missing plans:
  /plan-all-phases from <master-plan>
```

### Step 2: Determine starting point

Check which phases are already implemented:
1. For each phase plan, read its task list
2. Check git log for commits matching that phase's commit messages
3. Check if the files in the plan's Task Dependencies table have been modified

Build a status map:
```
Phase 1: IMPLEMENTED (commits found, all files present)
Phase 2: PARTIAL (tasks 1-3 committed, tasks 4-6 pending)
Phase 3: NOT STARTED
Phase 4: NOT STARTED
```

If the user specified `starting at phase N`, use that. Otherwise, start at the first phase that is NOT fully implemented.

### Step 3: Present the execution plan and confirm

Show the user what will happen:

```
## Project Implementation Plan

| Phase | Plan | Status | Action |
|-------|------|--------|--------|
| 1 | phase1-color-system-and-assets | Implemented | Skip |
| 2 | phase2-tab-bar-and-navigation | Partial (3/6 tasks) | Resume at task 4 |
| 3 | phase3-avatar-screen | Not started | Implement |
| 4 | phase4-furnace-screen | Not started | Implement |
| 5 | phase5-chat-screen | Not started | Implement |
| 6 | phase6-settings-screen | Not started | Implement |
| 7 | phase7-micro-interactions | Not started | Implement |

Estimated phases to execute: 6 (Phase 2 partial + Phases 3-7)

Proceed? (Phases will be implemented sequentially, with user checkpoints between each.)
```

Wait for user confirmation before proceeding.

### Step 4: Execute each phase

For each phase to implement, follow the full instructions from the `project-planner:implement-phase` skill. This includes:
- Pre-requisite verification
- Task-by-task execution
- Build verification after each task
- Commits per task
- Final verification

### Step 5: Checkpoint between phases

After each phase completes, present a checkpoint:

```
## Phase N Complete — Checkpoint

### Summary
- Tasks completed: X/Y
- Commits created: X
- Build status: PASSING
- Deviations from plan: (list or "none")

### What's next
Phase N+1: <name> — <goal summary>
- Tasks: X tasks in Y parallel groups
- Estimated scope: <files count> files

Continue to Phase N+1? [yes / skip to phase M / stop here]
```

**Wait for user confirmation** before proceeding to the next phase. This gives the user a chance to:
- Review what was built
- Test in the simulator/browser
- Adjust plans for later phases if needed
- Take a break and resume later

If the user says "stop here", save the progress state:
```
To resume later, run:
  /implement-project starting at phase <N+1>
```

### Step 6: Project completion

After all phases are implemented:

1. Run a full clean build of the entire project
2. Present the final summary:

```
## Project Implementation Complete

### Phases implemented:
| Phase | Tasks | Commits | Status |
|-------|-------|---------|--------|
| 1 | 8/8 | 8 | Passing |
| 2 | 6/6 | 6 | Passing |
| ... | ... | ... | ... |

### Total commits: N
### Final build: PASSING

### Deviations log:
- Phase 2, Task 3: <deviation description>
- (or "No deviations from plans")

### Post-implementation checklist:
- [ ] Visual review in simulator
- [ ] Test all user flows
- [ ] Check light/dark mode
- [ ] Performance check (no jank)
```

3. Update `docs/plans/PHASE-INDEX.md` if it exists, marking all phases as `Implemented`

---

## Handling long-running projects

For projects with many phases, each `/implement-project` session may only complete a few phases before hitting context limits. The checkpoint system ensures:
- Every completed phase is committed and the repo is in a buildable state
- The user can resume with `/implement-project starting at phase N`
- TodoWrite tracks in-progress tasks within a phase

## Important rules

1. **Never skip the checkpoint** — Always pause between phases for user confirmation
2. **Never skip a phase** — Phases must be executed in order (unless the user explicitly asks to skip)
3. **Phase plans are the source of truth** — Don't improvise beyond what the plans specify
4. **Each phase must build** — Never proceed to Phase N+1 if Phase N has a broken build
5. **Document everything** — Deviations, errors, and fixes are all logged in the final summary
