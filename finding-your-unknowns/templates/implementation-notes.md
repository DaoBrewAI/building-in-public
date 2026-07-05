# Implementation Notes — <task name>

> Use this file for large builds or implementation work. For medium read-only
> diagnostics, do not create this file; inline the compact
> hypothesis/discriminator report instead.

> A living log kept **during** the build. Its job: make sure a later attempt, a
> teammate, or a fresh session inherits what this session learned instead of
> re-hitting the same walls. Append as you go — do not wait until the end.

## User starting point
<!-- Captured before touching the code or drafting the Unknowns Map. Feeds
     the rest of the file. -->

- **Goal shape (what final good looks like):**
- **Acceptance evidence (what proves it works):**
- **Out of scope:**
- **Current hypothesis:**
- **Experience with this problem / codebase:**
- **Already known (facts, constraints they can state cleanly):**
- **Suspicions (unverified):**
- **"Good" looks like:**

## Starting context (post-scan)
<!-- The clean prompt, kept separate from codebase context. -->

- **Goal (one sentence):**
- **Prompt (separate from codebase context):**
- **Files / docs / tests scanned:**
- **References gathered (comparable code, docs, diagrams, external):**

## Unknowns Map
<!-- Every open item, tagged with a quadrant. Resolve in blast-radius order —
     answers that change architecture / data model / API / UX / dependencies /
     irreversible choices first. -->

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |

## Open questions
<!-- Known unknowns still live at the start. Cross them off as the interview /
     prototypes / blindspot pass answer them. Architecture-shaping questions
     go at the top. -->

- [ ]
- [ ]

## Blindspot findings
<!-- Output of the blindspot pass. Conventions, coupling, and hidden
     constraints the prompt never named. Tie each finding to a specific file,
     behavior, or dependency. Highest-value rows in this file. -->

-
-

## Artifacts / references carried into implementation
<!-- The lean bundle to carry into a fresh implementation session, if this is
     a large build. Only what's needed — no discovery transcript. -->

- **Distilled prompt (post-discovery, specificity dial set):**
- **Selected artifacts (chosen prototype, sample data, chosen intervention range):**
- **References to read first (files / docs / diagrams):**
- **Plan (link or paste):**

## Decision log
<!-- Each real decision AND its reasoning, in order. "Chose X over Y because
     Z" lets a later reader reevaluate when Z changes. -->

| # | Decision | Why | Alternatives rejected | Reversibility |
|---|----------|-----|-----------------------|----------------|
| 1 |          |     |                       |                |

## Deviations from the plan
<!-- Unexpected surprises. If reversible: conservative option, logged, keep
     working. If it changes architecture or product behavior: stop and confirm. -->

- **Surprise:**
  - What I expected:
  - What was actually true:
  - Conservative choice made:
  - Follow-up needed / revisit if:

## Handoff summary (post-implementation)
<!-- Fill at the end. Feeds the explainer and the pre-merge quiz. -->

- **What changed and why:**
- **What unknowns were resolved and how:**
- **What's still open / risky:**
- **What the next person should read first:**
