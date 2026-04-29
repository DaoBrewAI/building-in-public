---
name: plan-all-phases
description: "Generate implementation plans for all remaining phases of a project in batch. Use when you have a master plan with multiple phases and want to generate detailed plans for all of them at once, with proper dependency chaining between phases."
user-invocable: true
argument-hint: "from <master_plan_path> [starting at <phase_number>]"
---

# /plan-all-phases — Generate implementation plans for all remaining phases of a project

## Usage

```
/plan-all-phases from <master_plan_path>
/plan-all-phases from <master_plan_path> starting at <phase_number>
```

**Arguments:**
- `master_plan_path` — Path to the master project plan (relative or absolute)
- `phase_number` (optional) — Start generating from this phase (skips earlier ones). Default: generates all phases that don't already have plans.

**Examples:**
```
/plan-all-phases from docs/plans/2026-03-08-figma-to-ios-integration-design.md
/plan-all-phases from docs/plans/master-plan.md starting at 3
```

If no arguments are provided, ask the user for the master plan path.

---

## Instructions

You are a planning agent that generates detailed implementation plans for every phase in a multi-phase project, storing each as a separate file.

### Step 1: Read the master plan

Read the master plan file. Extract the complete list of phases with:
- Phase number and name
- Description and scope
- Files affected
- High-level steps

### Step 2: Identify which phases already have plans

Scan `docs/plans/` for existing phase plans (files matching `*-phase*`). Build a map:

```
Phase 1: docs/plans/2026-03-09-phase1-color-system-and-assets.md (EXISTS)
Phase 2: docs/plans/2026-03-09-phase2-tab-bar-and-navigation.md (EXISTS)
Phase 3: (MISSING — needs generation)
Phase 4: (MISSING — needs generation)
...
```

Present this map to the user and confirm which phases to generate. If the user said "starting at N", skip phases before N regardless of existence.

### Step 3: Read all existing phase plans

Read every existing phase plan to understand:
- What has been planned and the level of detail used
- Formatting conventions and structure
- "Notes for Subsequent Phases" sections — these contain critical context for generating later plans
- What outputs (files, components, APIs) earlier phases produce

### Step 4: Explore the codebase

Read source files relevant to the phases being generated. Understand the current project state.

### Step 5: Generate each missing phase plan sequentially

For each phase that needs a plan, generate it following the EXACT template and principles defined in the `project-planner:plan-phase` skill. Use the Skill tool to invoke `project-planner:plan-phase` for reference, or follow its template directly.

**Critical: chain dependencies properly.** When generating Phase N+1, reference the concrete outputs from the Phase N plan you just generated (not just the master plan's vague description). Each phase plan should:
- List specific pre-requisites from earlier phases
- Reference exact file paths, component names, and API surfaces from prior plans
- Include fallback strategies if prior phases aren't complete yet
- Document what it produces for later phases

Save each plan to:
```
docs/plans/YYYY-MM-DD-phase<N>-descriptive-slug.md
```

**STRICT naming convention** (required for automation — `/implement-phase` relies on this pattern):
- `phase<N>` uses the word "phase" immediately followed by the number with NO space or separator (e.g., `phase3`, `phase12`)
- Example: `2026-03-09-phase3-avatar-screen.md`, `2026-03-09-phase4-furnace-screen.md`

### Step 6: Generate a phase index

After all plans are generated, create or update a phase index file:

```
docs/plans/PHASE-INDEX.md
```

With this structure:

```markdown
# Project Phase Index

**Master plan:** <path to master plan>
**Generated:** YYYY-MM-DD

| Phase | Plan File | Status | Description |
|-------|-----------|--------|-------------|
| 1 | [Phase 1: ...](./2026-03-09-phase1-...) | Planned | ... |
| 2 | [Phase 2: ...](./2026-03-09-phase2-...) | Planned | ... |
| ... | ... | ... | ... |

## Dependency Chain

Phase 1 → Phase 2 → Phase 3 → ...
                  ↘ Phase 4 (can parallel with 3)

## Quick Reference

### Phase 1 outputs:
- <list of files/components created>

### Phase 2 outputs:
- ...
```

### Step 7: Present summary

Tell the user:
- How many phase plans were generated
- File paths for each
- A dependency diagram showing which phases can be parallelized
- Any assumptions or questions about scope

### Parallelism strategy

When generating plans, use the Agent tool to launch **up to 3 parallel agents** for phases that are independent of each other. For example, if Phase 4 and Phase 5 don't depend on each other, generate both simultaneously. Phases that depend on each other's outputs must be generated sequentially.

### Quality gates

Before saving each phase plan, verify:
- [ ] All file paths reference real files in the codebase (or clearly mark new files)
- [ ] Pre-requisites reference concrete outputs from earlier phase plans
- [ ] Every task has exact code/commands (not vague descriptions)
- [ ] Task dependency table has no circular dependencies
- [ ] Build verification step uses correct build command for the project
- [ ] Commit messages follow conventional commit format
