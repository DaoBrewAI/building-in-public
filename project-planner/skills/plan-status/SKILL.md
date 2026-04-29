---
name: plan-status
description: "Show the status of all project phases as a dashboard. Use when you want to see which phases have plans, which are implemented, which are in progress, and what actions to take next."
user-invocable: true
argument-hint: "[for <master_plan_path>]"
---

# /plan-status — Show the status of all project phases

## Usage

```
/plan-status
/plan-status for <master_plan_path>
```

Shows which phases have plans, which are implemented, and what's next.

---

## Instructions

### Step 1: Find the master plan

If a path is provided, use it. Otherwise, look in `docs/plans/` for files that define multiple phases (look for "Phase 1", "Phase 2", etc. patterns, excluding files that match `-phase<N>-` which are individual phase plans). If multiple candidates exist, ask the user which one.

### Step 2: Scan for phase plans

List all files in `docs/plans/` matching the glob pattern `*-phase*-*.md`. For each file:
- Extract the phase number from the filename pattern `-phase<N>-` (e.g., `phase1`, `phase3`)
- Extract the title from the first `#` heading in the file
- Note the file creation date from the filename prefix

### Step 3: Cross-reference with the master plan

Read the master plan to get the full list of phases. Compare against discovered phase plan files. Build the status map.

### Step 4: Check implementation status

For each phase that has a plan:
1. Read the plan's Task Dependencies table to get the task count
2. Search git log for commits referencing that phase:
   ```bash
   git log --oneline --all --grep="phase<N>" --grep="Phase <N>" -i
   ```
3. Check if the key files listed in the plan exist and have been modified after the plan was created
4. Classify as:
   - **Implemented** — all tasks have matching commits and files exist
   - **In Progress** — some but not all tasks have matching commits
   - **Planned** — plan exists but no implementation commits found
   - **No Plan** — phase exists in master plan but no plan file generated

### Step 5: Present the dashboard

```
## Project Phase Dashboard

Master plan: <path>

| # | Phase | Plan File | Plan Status | Implementation | Next Action |
|---|-------|-----------|-------------|----------------|-------------|
| 1 | Color System & Assets | phase1-color-system-... | Written | Implemented | — |
| 2 | Tab Bar & Navigation | phase2-tab-bar-... | Written | In Progress | `/implement-phase 2 starting at task 4` |
| 3 | Avatar Screen | — | Missing | — | `/plan-phase 3 from <master>` |
| 4 | Furnace Screen | — | Missing | — | `/plan-phase 4 from <master>` |
| ... | ... | ... | ... | ... | ... |

### Quick Actions

**Next planning step:** `/plan-phase 3 from <master-plan-path>`
**Next implementation step:** `/implement-phase 2 starting at task 4`
**Generate all missing plans:** `/plan-all-phases from <master-plan-path> starting at 3`
**Implement everything remaining:** `/implement-project starting at phase 2`
```

The "Next Action" column should contain the exact command the user can copy-paste.

### Step 6: Dependency warnings

If any phase is marked for implementation but has unimplemented dependencies, add a warning:

```
### Dependency Warnings
- Phase 3 depends on Phase 1 (Implemented) and Phase 2 (In Progress)
  → Phase 2 must be completed before Phase 3 can be implemented
```
