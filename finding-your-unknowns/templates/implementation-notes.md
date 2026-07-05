# Implementation Notes - <task name>

Use this file for large builds or implementation work. Do not create it for
medium read-only diagnostics; inline the compact hypothesis report instead.

Keep this file live while building. Its job is to let a later Codex session,
teammate, or continuation loop inherit what this session learned.

## Goal Frame

- **Goal source:** active Codex Goal / `docs/loop/goal.md` / inferred from prompt
- **Done looks like:**
- **Acceptance evidence:**
- **Out of scope:**
- **Current hypothesis:**
- **Known constraints:**
- **Suspicions not yet verified:**
- **Taste / "good" signal, if relevant:**

## Loop Context

Fill this when running with `$codex-loop-engineering`.

- **Loop files read:** `goal.md`, `tracker.md`, `constraints.md`, `handoff.md`
- **Current tracker item:**
- **Hard constraints from `constraints.md`:**
- **Prior unknowns from `handoff.md`:**
- **Handoff section updated:**

## Project Scan

- **Files / docs / tests scanned:**
- **Comparable code found:**
- **Relevant interfaces / schemas / APIs:**
- **Existing invariants or conventions:**

## Unknowns Map

Include only unknowns whose answers change architecture, data model, API shape,
UX flow, dependencies, or irreversible choices.

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |

## Deferred Questions

Use when the user cannot answer live.

| Question | Options | Default if unanswered | Why it matters | What would change |
|---|---|---|---|---|
|  |  |  |  |  |

## Blindspot Findings

Classify before presenting. Do not call likely-by-design or roadmap-gap items
bugs.

| Finding | Class | Evidence | Follow-up |
|---|---|---|---|
|  | bug-likely / architecture risk / likely by design / roadmap gap |  |  |

## Plan

- **Plan status:** proposed / approved / revised
- **Data or API decisions:**
- **User-facing decisions:**
- **Verification required:**

## Decision Log

| # | Decision | Why | Alternatives rejected | Reversibility |
|---|---|---|---|---|
| 1 |  |  |  |  |

## Deviations

Log surprises as they happen.

- **Surprise:**
  - Expected:
  - Actual:
  - Conservative choice:
  - Follow-up:

## Handoff Summary

- **What changed and why:**
- **Unknowns resolved and how:**
- **Unresolved assumptions to carry forward:**
- **What the next Codex session should read first:**
- **Continuation prompt, if any:**
