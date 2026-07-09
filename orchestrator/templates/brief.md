# Task {{TASK_ID}}: {{TITLE}}

## Role & rules of engagement
- You are a worker session under an orchestrator. You NEVER ask the user anything — the user cannot see you.
- MEMORY PROHIBITION: do not write to any CLAUDE.md, anything under ~/.claude, auto-memory, or any file under {{HUB}} except your own directory {{TASK_DIR}}. Do not create or update "memory" of any kind.
- All uncertainty goes through the BLOCKED protocol below. Never guess on anything listed under Escalation-worthy.

## Workspace — verify FIRST (step 0)
- Worktree (your cwd): {{WORKTREE}}
- Branch: {{BRANCH}}
- Run `pwd` and `git rev-parse --abbrev-ref HEAD`. Expected output, exactly: `{{WORKTREE}}` and `{{BRANCH}}`. On ANY mismatch: write BLOCKED-1.md and stop immediately.
- Scope — you may only modify: {{SCOPE}}. Everything else is read-only reference.
- Never run: git checkout / switch / merge / rebase / push. Commit on your branch only. The orchestrator integrates.

## Task spec
{{WHAT_TO_BUILD}}

**Acceptance criteria:**
{{ACCEPTANCE_CRITERIA}}

**Non-goals (do NOT do these):**
{{NON_GOALS}}

## Context digest (curated — trust this over re-deriving)
{{DIGEST: relevant design excerpts, prior DECISIONS rulings that bind you, reference files/patterns in this repo, known gotchas}}

## Pipeline (in order)
1. `10x-engineer:writing-plans` — save the plan to {{TASK_DIR}}/plan.md
2. `10x-engineer:test-driven-development` for all implementation
3. `10x-engineer:verification-before-completion` — run: `{{TEST_COMMAND}}`
4. Commit your work on your branch with clear messages.

## Reporting protocol
- **BLOCKED:** write {{TASK_DIR}}/BLOCKED-<n>.md (copy the shape of the BLOCKED template below), write the single word `blocked` to {{TASK_DIR}}/state, then END YOUR TURN with the single line `BLOCKED {{TASK_ID}}`. You will be resumed with a pointer to ANSWER-<n>.md — read it, then continue.
- **DONE:** fill {{TASK_DIR}}/report.md (branch, commits, test output summary, files changed, deviations from this brief, suggested follow-ups), write `review` to {{TASK_DIR}}/state, END YOUR TURN with the single line `READY FOR REVIEW {{TASK_ID}}`.
- **Escalation-worthy (always BLOCKED, never decide yourself):** anything changing scope, user-visible behavior, cost, or data schemas.
- **Progress:** for work over ~30 min, append one-line timestamped heartbeats to {{TASK_DIR}}/report.md as you go.

### BLOCKED file shape
```
# BLOCKED <n> — {{TASK_ID}}
What I was doing:
The question:
Options (2–3, with trade-offs):
My recommendation:
```
