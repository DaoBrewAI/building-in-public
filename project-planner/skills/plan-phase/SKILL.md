---
name: plan-phase
description: "Generate a detailed implementation plan for a single project phase. Use when you need to break down one phase of a multi-phase project into executable tasks with exact code, parallel groups, build verification, and commit steps."
user-invocable: true
argument-hint: "<phase_number> from <master_plan_path>"
---

# /plan-phase — Generate a detailed implementation plan for a single project phase

## Usage

```
/plan-phase <phase_number> from <master_plan_path>
```

**Arguments:**
- `phase_number` — The phase to generate (e.g., `3`, `4`, `5`)
- `master_plan_path` — Path to the master project plan that defines all phases (relative or absolute)

**Examples:**
```
/plan-phase 3 from docs/plans/2026-03-08-figma-to-ios-integration-design.md
/plan-phase 5 from docs/plans/master-plan.md
```

If no arguments are provided, ask the user which phase number to generate and which master plan to use.

---

## Instructions

You are a planning agent that generates detailed, task-level implementation plans for individual phases of a multi-phase project.

### Step 1: Read the master plan

Read the master plan file specified by the user. Extract:
1. **All phase definitions** — names, descriptions, files affected, steps
2. **The specific phase** the user requested
3. **Dependencies** — what previous phases produce that this phase depends on
4. **What subsequent phases** will need from this phase

### Step 2: Read prior completed phase plans

Look in `docs/plans/` for any existing phase plans for this project (files matching the pattern `*-phase*`). Read them to understand:
- What has already been planned/implemented
- What outputs (files, components, APIs) are available from earlier phases
- The naming conventions, formatting style, and level of detail used
- Any "Notes for Subsequent Phases" sections that reference the current phase

### Step 3: Explore the codebase

Read the actual source files that this phase will touch. Understand:
- Current file contents and structure
- What code already exists vs what needs to be created
- Existing patterns, naming conventions, and architecture
- Any changes already made by prior phases

### Step 4: Generate the phase plan

Create a new file at:
```
docs/plans/YYYY-MM-DD-phase<N>-descriptive-slug.md
```

**STRICT naming convention** (required for automation — `/implement-phase` relies on this pattern):
- `YYYY-MM-DD` is today's date
- `phase<N>` uses the word "phase" immediately followed by the number with NO space or separator (e.g., `phase3`, `phase12`)
- `descriptive-slug` is a kebab-case summary of the phase goal (e.g., `avatar-screen`, `chat-redesign`)
- Example: `2026-03-09-phase3-avatar-screen.md`, `2026-03-09-phase4-furnace-screen.md`

The plan MUST follow this structure:

---

```markdown
# Phase N: Title — Short Description

> **For Claude:** REQUIRED SUB-SKILL: Use 10x-engineer:executing-plans to implement this plan task-by-task.

**Goal:** One paragraph describing the concrete outcome of this phase.

**Architecture:** One paragraph describing the technical approach — what gets created, modified, and how components connect.

**Tech Stack:** Comma-separated list of frameworks, tools, and technologies used

**Project root:** `<absolute path to project root>`

---

## Task Dependencies

Tasks in the same parallel group can be worked on concurrently.
Tasks with dependencies must wait for their prerequisites.

| Task | Parallel Group | Depends On | Files Touched |
|------|---------------|------------|---------------|
| 1: Task name | A | — | `path/to/file` |
| 2: Task name | A | — | `path/to/file` |
| 3: Task name | B | Task 1 | `path/to/file` |
| ...  | ... | ... | ... |

**Parallel execution:** Description of which groups can run simultaneously.

---

## Reference: <Relevant Design Specs>

Source: `<source document/page>`

<Tables, code snippets, or specifications needed to implement this phase>

---

## Task 1: <Name>
**Parallel group:** <letter>

**Files:**
- Create/Modify: `<file path>`

**Step 1: <Action>**
<Precise instructions with exact code, commands, or file contents>

**Step 2: <Action>**
...

**Step N: Build to verify**
```bash
<build/test command>
```
Expected: <what success looks like>

**Step N+1: Commit**
```bash
git add <specific files>
git commit -m "<conventional commit message>"
```

---

## Task 2: <Name>
...

---

## Task N (last): Build Verification & Fix Compile Errors
**Parallel group:** <last letter> (depends on all previous tasks)

**Files:**
- Any files with compile errors

**Step 1: Full clean build**
<build command>

**Step 2: Fix any compile errors**
Common issues to check:
1. <issue and fix>
2. ...

**Step 3: Verify checklist**
- [ ] <verification item>
- [ ] ...

**Step 4: Final commit**

---

## Notes for Subsequent Phases

Phase N establishes <what> that later phases build on:

- **Phase N+1 (<name>)** will use <specific outputs from this phase>
- **Phase N+2 (<name>)** will use <specific outputs from this phase>
- ...

## Pre-requisites from Previous Phases

This plan assumes the following phases have been completed:
- <specific outputs/files/components from earlier phases>

If previous phases are not complete, use these fallbacks:
- <fallback approach for each dependency>
```

---

### Key principles for plan quality

1. **Every task must be independently executable** — include exact file paths, code snippets, and commands. Another Claude session should be able to execute this plan without asking questions.

2. **Maximize parallelism** — group tasks into parallel groups (A, B, C...) where independent work can happen simultaneously. Only add dependencies when tasks genuinely conflict on the same files or need outputs from each other.

3. **Include the actual code** — don't say "update the colors". Show the exact Swift/Python/etc. code to write. Reference exact hex values, pixel sizes, font names from the design specs.

4. **Each task ends with build verification + commit** — every task should leave the project in a compilable state with a focused commit.

5. **Reference specs inline** — include relevant design system values (colors, sizes, spacing) directly in the plan. Don't make the implementer look them up.

6. **Pre-requisites and fallbacks** — explicitly state what this phase needs from prior phases and what to do if those aren't ready yet.

7. **Notes for future phases** — document what this phase produces that later phases will consume.

### Step 5: Present the plan

After writing the file, tell the user:
- The file path where the plan was saved
- A summary of the tasks and their parallel groups
- Any assumptions made or questions about the phase scope
