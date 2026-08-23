---
name: finding-your-unknowns
description: Surfaces and classifies task unknowns before and during non-trivial Codex coding work. Use when the user asks to find unknowns, map known knowns / known unknowns / unknown knowns / unknown unknowns, investigate an ambiguous bug, work in an unfamiliar codebase, make an architecture / data-model / API / UX decision, build a taste-heavy surface, or run a repo-loop checkpoint that may derail on hidden constraints. Starts from the active Codex Goal or an inferred goal frame, keeps medium diagnostics compact with ranked hypotheses, decisive discriminators, down-ranked blindspots, and deferred questions, and integrates with codex-loop-engineering by carrying unresolved assumptions into docs/loop/handoff.md. Skip trivial edits.
---

# Finding Your Unknowns

Use this skill to keep Codex from turning early uncertainty into confident
guesses. The prompt, skills, and visible context are the map; the actual
project, constraints, runtime behavior, and user's taste are the territory.

This is a toolbox, not ceremony. Pick one scaled mode and stay inside it unless
the task clearly changes shape.

## First Move In Codex

Anchor the target state before broad discovery.

1. If a Codex Goal is active or the user invoked `/Goal`, treat that goal as the
   primary known known: final state, acceptance evidence, non-goals, and budget.
   Do not create a new Goal unless the user explicitly asked for one.
2. If the repo has `docs/loop/{goal,tracker,constraints,handoff}.md`, or the user
   also invokes `$codex-loop-engineering`, read the loop files first. Treat:
   - `goal.md` as the goal frame,
   - `tracker.md` as the current checkpoint boundary,
   - `constraints.md` as hard guardrails,
   - `handoff.md` as prior unresolved unknowns and continuation context.
3. If no Goal or loop files exist, infer a one-paragraph Goal frame and mark it
   as inferred. Ask for correction only when the missing answer would change
   architecture, data model, API shape, UX flow, dependencies, or an irreversible
   choice.

## The Four Quadrants

Classify open items by how they should be resolved.

| Quadrant | What it is | How to close it |
|---|---|---|
| Known knowns | Facts stated by the user, active Goal, loop files, or visible code | Keep explicit and referenceable. |
| Known unknowns | Questions the user or repo already names | Ask focused questions with concrete options. |
| Unknown knowns | Taste, product intuition, or "I'll know it when I see it" knowledge | Show options: scope lists, interface sketches, comparable code, prototypes, tradeoff cards. |
| Unknown unknowns | Constraints nobody named yet | Run a repo-grounded blindspot pass before building. |

## Pick Exactly One Mode

- **Trivial edit**: one-line fix, rename, copy tweak, or mechanical change with
  an obvious correct answer. Skip this skill.
- **Medium diagnostic / read-only investigation**: default for ambiguous bugs,
  unfamiliar modules, and root-cause hunts. Do not create
  `implementation-notes.md`, full quadrant tables, prototypes, fresh-session
  handoffs, or broad plans. Return only:
  1. Goal frame: what done looks like and what evidence would prove it,
  2. up to 3 ranked hypotheses,
  3. one decisive discriminator per hypothesis,
  4. up to 3 repo-grounded blindspots, with likely-by-design and roadmap gaps
     down-ranked,
  5. up to 4 architecture-changing questions, or deferred questions if the user
     cannot answer live.
- **Large build / loop checkpoint**: multi-file implementation, new subsystem,
  irreversible data/API decision, taste-heavy product surface, or a long-running
  repo loop. Use the full workflow: Goal frame, project scan, Unknowns Map,
  resolving moves, plan, implementation notes, and handoff.

The selected mode is binding. Do not silently upgrade a medium diagnostic into
the full workflow.

## Discovery Workflow

### 1. Capture The Starting Point

Record only the fields that matter for the selected mode:

- Goal shape and acceptance evidence.
- Current user or agent hypothesis.
- User familiarity with the problem/codebase, if known.
- Already known facts and constraints.
- Suspicions not yet verified.
- What "good" should feel like, when taste or UX is involved.

Use `request_user_input` only when it is available and the answer is
architecture-shaping. Otherwise ask in chat with concrete options. In autonomous
runs, write deferred questions and continue only under conservative reversible
defaults.

### 2. Inspect The Real Project

Skim the relevant surface before inventing questions or blindspots:

- directory structure for the affected area,
- public interfaces, types, schemas, APIs,
- adjacent tests and fixtures,
- README / ADR / config files,
- existing patterns for similar work.

Every question, hypothesis, and blindspot must tie back to a file, behavior,
constraint, or explicit user decision.

### 3. Medium Diagnostics: Rank Hypotheses First

For bugs and read-only investigations, prefer a hypothesis map over a full
quadrant inventory.

| Rank | Hypothesis | Evidence | Decisive discriminator | What would change my mind | Status |
|---|---|---|---|---|---|

Do not collapse to one root cause until the discriminators have been checked.
This is the skill's main differentiator over generic "assumptions / not checked"
lists.

Before presenting blindspots, classify and down-rank them:

- `bug-likely`: contradicts tests, docs, schemas, call-site expectations, or
  observed behavior.
- `architecture risk`: plausible hidden coupling or invariant; needs verification.
- `likely by design`: repeated pattern, named abstraction, docs/tests encode it,
  or no caller expects the missing behavior.
- `roadmap gap`: not implemented yet, but no current code path requires it.

### 4. Large Builds: Draft A Small Unknowns Map

Use a compact table. Include only items whose answers change architecture, data
model, API/interface shape, UX flow, dependencies, or irreversible choices.

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|

Resolve cheapest first:

- Known knowns: note and reference.
- Known unknowns: ask a focused question with 2-4 concrete options.
- Unknown knowns: show concrete options, prototypes, comparable code, or
  tradeoff cards.
- Unknown unknowns: blindspot pass grounded in specific repo files.

Read `templates/techniques.md` only when you need example prompts or per-quadrant
templates.

### 5. Plan After The Unknowns Are Small Enough

Use `update_plan` when a plan is useful, with at most one `in_progress` item.
Weight the plan toward parts expensive to change late: data models, type or API
interfaces, user-facing flows, migrations, and dependencies. Keep mechanical
steps brief.

If a user answer is still needed but no live user is available, add a Deferred
Questions table:

| Question | Options | Default if unanswered | Why it matters | What would change |
|---|---|---|---|---|

Proceed only when the default is reversible. If no reversible default exists,
stop at findings.

## Codex Loop Engineering Integration

When this skill runs inside a `$codex-loop-engineering` project:

1. Do not replace the loop contract. The loop files stay authoritative.
2. Treat the current unchecked tracker item as the task boundary for the
   Unknowns Map.
3. Keep medium diagnostics inline in the response or `handoff.md`; do not create
   extra files.
4. For large builds, create or update `implementation-notes.md` near the loop
   files unless the repo has a stronger convention. Link it from
   `docs/loop/handoff.md`.
5. If discovery changes the checkpoint sequence, update `tracker.md` before
   implementing.
6. Before any continuation session, write unresolved assumptions, deferred
   questions, selected defaults, and the distilled post-discovery prompt into
   `docs/loop/handoff.md`.
7. If unresolved architecture-shaping questions remain, mark the loop blocked
   instead of auto-chaining into implementation.

The clean continuation prompt should name both skills when both are needed:

```text
Use $codex-loop-engineering and $finding-your-unknowns.
First read docs/loop/goal.md, tracker.md, constraints.md, handoff.md, then
continue the next unchecked tracker item under the unresolved assumptions listed
in handoff.md.
```

## During Implementation

- Keep `implementation-notes.md` live for large builds and implementation work.
  Start from `templates/implementation-notes.md`. Do not create it for medium
  read-only diagnostics.
- On reversible surprises, choose the conservative option, log the deviation,
  and keep working.
- On surprises that change architecture or product behavior, stop and confirm.
- Keep prompt/spec context separate from codebase observations so a fresh session
  can inherit the distilled signal instead of the whole discovery transcript.

## Output Contracts

For medium diagnostics, output only:

1. Goal frame.
2. Ranked hypotheses and discriminators.
3. Down-ranked blindspots.
4. Deferred questions or concrete user questions.
5. Final root-cause confidence after discriminators are checked.

For large builds or loop checkpoints, output:

1. Goal frame.
2. Unknowns Map.
3. Resolved decisions and defaults.
4. Plan.
5. Implementation notes path, if created.
6. Handoff updates, if inside a loop.

## Guiding Principle

Prefer cheap discovery before expensive implementation. The win is not more
process; it is fewer wrong turns.
