---
name: change-walkthrough
description: Use after implementation is complete and code review has finished, especially after long autonomous runs - produces an HTML understanding report (context, intuition, what changed, deviations, risks) with a quiz the human must pass. Trigger when the user asks to understand what happened in a change, or after finishing-a-development-branch on multi-hour work.
---

# Change Walkthrough

The human is about to own code they didn't watch being written. Produce a report that transfers understanding, then verify the transfer with a quiz. **Passing the quiz is the exit criterion, not sending the report.**

**Announce at start:** "I'm using the change-walkthrough skill to build your understanding report."

## Step 1 — Gather (do not skip sources)

- The diff: `git log --oneline` + `git diff --stat` for the change range (branch, or the merged range)
- The plan (`docs/plans/...`) and `implementation-notes.md` — especially `## Deviations`
- Code review findings and how each was resolved
- The status-truth doc if one exists (link it; don't duplicate its evidence tables)

## Step 2 — Write the HTML report

Use the `visualize:visualize` skill when available; otherwise save
`docs/plans/YYYY-MM-DD-<feature>-walkthrough.html` and tell the user to open it.
Sections, in order:

1. **Context** — the problem this change solves and what triggered it, in plain language
2. **Intuition** — the mental model: how the pieces fit, the one diagram or metaphor that makes the design click; what you'd sketch at a whiteboard for a teammate
3. **What was done** — walkthrough by area (not by commit): file paths, the key excerpts, and why each piece looks the way it does
4. **Deviations & judgment calls** — every entry from implementation-notes.md Deviations plus decisions made on the human's behalf, each with its why
5. **What to watch** — risks, weak spots, follow-ups; where the next bug will most likely surface
6. **Quiz** — at the bottom, 5–8 questions (see Step 3); questions only, no answers in the report

Write for understanding, not proof — full sentences, no jargon walls, no wall-of-diff.

## Step 3 — The quiz (must pass)

- Mix: roughly half conceptual ("why is X done via Y rather than Z"), half operational ("what happens if...", "where does ... live")
- At least one question about a Deviation and one about a What-to-watch risk
- The human answers in chat; grade honestly, quoting the relevant report section for every wrong or partial answer
- **Pass** = all critical questions correct (one miss allowed on detail questions)
- **Fail** = explain the gaps, then re-quiz only the missed areas with fresh questions — do not repeat the same questions
- Do not declare the workflow complete until the quiz is passed; record the outcome at the top of implementation-notes.md (e.g. `Walkthrough quiz: passed 7/8 — 2026-07-09`)

## Red flags

| Thought | Reality |
|---|---|
| "Report sent, I'm done." | The quiz is the point. Understanding unverified is understanding assumed. |
| "These questions might be too hard." | Questions answerable without reading the report are theater. |
| "Close enough, mark it passed." | Generous grading defeats the exit criterion. Quote the section, re-quiz. |
| "The diff is self-explanatory." | The human didn't watch it happen. That's why this skill exists. |
