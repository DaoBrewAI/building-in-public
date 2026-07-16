---
name: executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load plan, review critically, execute tasks in batches, report for review between batches.

**Core principle:** Batch execution with checkpoints for architect review.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

## The Process

### Step 1: Load and Review Plan
1. Read plan file
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with your human partner before starting
4. If no concerns: mirror the task list in `update_plan` and proceed

### Step 1.5: Create Implementation Notes
Create `implementation-notes.md` next to the plan file (e.g. `docs/plans/YYYY-MM-DD-<feature>-implementation-notes.md`) with three headings: `## Progress`, `## Deviations`, `## Surprises & Learnings`. Keep it updated as you work — one line per completed task under Progress. This file is the memory of the run; the change-walkthrough skill reads it at the end.

### Step 2: Execute Batch
**Default: First 3 tasks**

For each task:
1. Mark as in_progress
2. Follow each step exactly (plan has bite-sized steps)
3. Run verifications as specified
4. Mark as completed

### Step 3: Report
When batch complete:
- Show what was implemented
- Show verification output
- List any new entries under Deviations (or "No deviations")
- Say: "Ready for feedback."

### Step 4: Continue
Based on feedback:
- Apply changes if needed
- Execute next batch
- Repeat until complete

### Step 5: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use 10x-engineer:finishing-a-development-branch
- Follow that skill to verify tests, present options, execute choice
- After finishing and code review: for long runs or substantial changes, use 10x-engineer:change-walkthrough to hand the human an understanding report + quiz

## Deviations — edge cases that force a change from the plan

When an edge case forces you off the plan:
1. Pick the **conservative option** — smallest change, most reversible, least new surface area, zero scope creep.
2. Log it under `## Deviations` in implementation-notes.md: what the plan said · what you hit · what you did instead · why it's the conservative choice.
3. **Keep going.** A logged deviation does not stop the batch.

Deviations cover tactical adjustments only. Still STOP (below) when the deviation would change scope, user-visible behavior, data schemas, or the plan's architecture — those are the human's calls.

## When to Stop and Ask for Help

**STOP executing immediately when:**
- A needed deviation would change scope, user-visible behavior, data schemas, or architecture
- Hit a blocker mid-batch (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- Partner updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- **Change scope discipline** — Do not change existing behavior unless absolutely necessary for the current task. No drive-by refactors or cleanups. Only change what the task demands.
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Between batches: just report and wait
- Stop when blocked, don't guess
