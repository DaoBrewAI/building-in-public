---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for submitting PRs or cleanup
---

# Finishing Development Work

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests -> Present options -> Execute choice -> Clean up.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

Run the project's test suite.

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with PR submission until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Check Current Commit Status

```bash
# Check current branch and recent commits
git log --oneline -5
git status
```

### Step 3: Present Options

Present exactly these 4 options:

```
Implementation complete. What would you like to do?

1. Create draft PR (gh pr create --draft)
2. Create PR for review (gh pr create)
3. Keep changes as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 4: Execute Choice

#### Option 1: Create Draft PR

```bash
# If there are uncommitted changes, commit first
git status
# If changes exist:
git add -A
git commit -m "feat: <title>"

# Push and create draft PR
git push -u origin HEAD
gh pr create --draft --title "<title>" --body "<description>"
```

Report: "Draft PR created. You can mark as ready when you want review."

#### Option 2: Create PR for Review

```bash
# If there are uncommitted changes, commit first
git status
# If changes exist:
git add -A
git commit -m "feat: <title>"

# Push and create PR
git push -u origin HEAD
gh pr create --title "<title>" --body "<description>"
```

Report: "PR created for review. Check GitHub for status."

#### Option 3: Keep As-Is

Report: "Keeping changes as-is. You can push and create a PR later."

**Don't modify anything.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently discard:
- Uncommitted changes
- Current commit: <commit summary>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
git checkout -- .
git clean -fd
```

## Quick Reference

| Option | Commit | Push | PR |
|--------|--------|------|-----|
| 1. Draft PR | yes (if needed) | yes | draft |
| 2. PR for review | yes (if needed) | yes | ready |
| 3. Keep as-is | - | - | - |
| 4. Discard | - | - | - |

## Common Mistakes

**Skipping test verification**
- **Problem:** Submit broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" -> ambiguous
- **Fix:** Present exactly 4 structured options

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Proceed with failing tests
- Submit without verifying tests
- Delete work without confirmation
- Push without checking if changes are committed

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4

## Integration

**Called by:**
- **subagent-driven-development** - After all tasks complete
- **executing-plans** - After all batches complete
