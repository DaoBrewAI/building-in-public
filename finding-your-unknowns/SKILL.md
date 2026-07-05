---
name: finding-your-unknowns
description: Surfaces and classifies a user's task unknowns before and during non-trivial coding work. Use when a task has meaningful uncertainty: unfamiliar codebase or module, ambiguous bug report, architecture / data-model / API / UX decision, taste-heavy work, or long-horizon multi-file implementation. Starts from the user's goal shape ("what final good looks like"), hypothesis, and project context, then chooses a scaled mode. For medium diagnostics, keeps output compact: goal frame, ranked hypotheses, decisive discriminators, down-ranked blindspots, and deferred questions. For large builds, maps known knowns / known unknowns / unknown knowns / unknown unknowns and resolves each with the lightest move. Toolbox, not ceremony. Skips trivial edits.
---

# Finding Your Unknowns

The prompt, skills, and context you give the agent are the *map*; the actual project, constraints, and behavior are the *territory*. Every unknown the agent hits mid-task becomes a best-guess decision, and best-guess decisions compound on long tasks into rework risk.

This skill is a **toolbox** for surfacing what the user does not know they do not know — not a checklist to run every time. Pick the lightest technique that fits the task.

## The four quadrants

Classify every open item into one quadrant. Each is closed by a different lightweight move.

| Quadrant | What it is | How to close it |
|---|---|---|
| **Known knowns** | Facts stated in the prompt or already visible in the codebase | Keep them explicit and referenceable. |
| **Known unknowns** | Questions the user knows are open | Ask a focused question — prioritize answers that change architecture, data model, API shape, UX flow, dependencies, or an irreversible choice. |
| **Unknown knowns** | Things the user knows implicitly (taste, product intuition, "I'll know it when I see it") but can't specify cold | Show concrete options: intervention lists, prototypes, API/interface sketches, comparable code, tradeoff cards. Recognition beats specification. |
| **Unknown unknowns** | Things the user hasn't considered at all — the dangerous category | Blindspot pass grounded in the actual repo: read the relevant files, docs, tests, schemas; only then enumerate what's likely to bite. |

## Pick exactly one mode

Choose the mode before discovery. This is binding; do not silently upgrade a medium task into the full workflow.

- **Trivial edit**: one-line fix, rename, copy tweak, or mechanical change with an obvious correct answer. **Skip this skill entirely.**
- **Medium diagnostic / read-only investigation**: default for ambiguous bugs, unfamiliar modules, and root-cause hunts. Do **not** create `implementation-notes.md`, full quadrant tables, prototypes, plan mode, explainers, quizzes, or fresh-session handoffs. Output only:
  1. goal frame: what "done" looks like and what evidence would prove it,
  2. up to 3 ranked hypotheses,
  3. one decisive discriminator per hypothesis,
  4. up to 3 repo-grounded blindspots, with likely-by-design and roadmap gaps down-ranked,
  5. up to 4 architecture-changing questions with concrete options, or deferred questions if the user cannot answer live.
  Keep discovery output compact unless the user asks for the full map.
- **Large build**: multi-file implementation, new subsystem, irreversible data/API decision, or taste-heavy product surface. Use the full workflow: starting point, scan, Unknowns Map, resolving moves, plan, implementation notes, explainer / quiz, and possible fresh-session handoff.

## Unknown-discovery pass

Run only the moves allowed by the selected mode.

### 1. Start with the goal and the user's starting point

Before touching the code, anchor the target state, then capture the user's own frame:

- **Goal shape** — what the final thing should look like, and what evidence would prove it works.
- **Current hypothesis** — what they'd try if forced to guess.
- **Experience** — how well they know this problem and this codebase.
- **Already known** — facts and constraints they can state cleanly.
- **Suspicions** — things they think but haven't verified.
- **"Good" looks like** — the shape of a successful outcome, in their words.

If any of these are missing and the task isn't trivial, ask.

- **In Claude Code:** use **AskUserQuestion** with 2–4 concrete options per question.
- **Otherwise:** ask in normal chat, presenting concrete options rather than open-ended prompts.

### 2. Inspect the real project

Skim (don't deep-read) the actual surface relevant to the goal shape: directory structure, public interfaces, adjacent tests, READMEs / ADRs / config, existing patterns for similar work. Every downstream move — questions, blindspot pass, brainstorm — is grounded in what actually exists rather than textbook generalities.

### 3. For diagnostics: rank hypotheses first

For bug reports and read-only investigations, prefer a hypothesis map over a full quadrant inventory:

| Rank | Hypothesis | Evidence | Decisive discriminator | What would change my mind | Status |
|---|---|---|---|---|---|

Do not collapse to one root cause until the discriminators have been checked. This is the skill's main advantage over generic due diligence: keep several plausible branches alive, then kill them cheaply.

### 4. For large builds: draft a small Unknowns Map

A compact table where every open item is tagged with a quadrant and a resolving move. Something like:

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|
| Session cascade on user delete | known unknown | `users` FK on `sessions` | irreversible in prod | ask user (3 options) | user | open |
| Preferred error-modal shape | unknown known | UX call | user-facing, taste | show 3 variants | prototype | open |
| Middleware invariants | unknown unknown | `middleware/*` uninspected | can break existing flows | blindspot pass | agent | open |
| Runtime is Node 22 | known known | `package.json` | governs deps | note & move on | — | done |

Prioritize items whose answers change architecture, data model, API/interface shape, UX flow, dependencies, or an irreversible choice. Skip items whose answer wouldn't change what you build.

### 5. Resolve, cheapest first

Pick the lightest per-quadrant technique. See `templates/techniques.md` for prompt shapes, templates, and worked examples.

- **Known knowns** → note and reference.
- **Known unknowns** → focused question(s) with concrete options.
- **Unknown knowns** → show options. Match the medium to what's being decided (see below).
- **Unknown unknowns** → blindspot pass grounded in specific files.

**Brainstorming has more than one mode.** Reach for the right one:

- **Concept / scope brainstorm** — enumerate intervention points from cheapest to most ambitious (a "10 options" list). Best when the *shape of the fix* is uncertain.
- **Codebase-search brainstorm** — search the repo for existing patterns and comparable implementations before designing.
- **Prototype / artifact brainstorm** — 3–5 *meaningfully different* directions when the blocker is visual, interactive, or taste-heavy.

### 6. Plan only after the map is resolved enough

Write the plan when remaining unknowns are small enough to absorb during the build. Weight it toward parts most expensive to change late — data models, type/interface shapes, user-facing surface. Skim the mechanical parts.

- **In Claude Code:** use **plan mode / ExitPlanMode**.
- **Otherwise:** write the plan as a message or a `plan.md` and get explicit user approval.

## The specificity dial

Being too specific is as bad as being too vague.

- **Too specific** → the agent follows instructions rigidly even when changing course would obviously be better.
- **Too vague** → the agent fills gaps with industry defaults that don't fit *this* task.

Set the dial only *after* resolving the map: be concrete where you have real knowledge, deliberately open where the model's judgment should win, and say so.

## During implementation (medium and large builds)

- **Keep `implementation-notes.md` live for large builds and implementation work** (start from `templates/implementation-notes.md`). Do not create it for medium read-only diagnostics.
- **On surprises**: if the deviation is reversible, pick the conservative option, log it, and keep working. If it changes architecture or product behavior, stop and confirm.
- **Capture surprises that mattered** — those are the unknown unknowns the map missed, and they feed the next attempt.
- **Keep the prompt separated from codebase context** so recovery from wrong turns stays cheap.

## Hand off to a fresh implementation session (large builds)

Discovery bloats context. For a large build, once the map is resolved and the plan is approved, hand off to a fresh session with a lean bundle:

- the **distilled prompt** (post-discovery, specificity dial set)
- the **selected artifacts** (chosen prototype, sample data, chosen intervention range)
- the **references** to read first (specific files, docs)
- the **approved plan**
- `implementation-notes.md` seeded with starting point, surviving open questions, and blindspot findings

This starts the implementation agent with concentrated signal — not the meandering discovery transcript.

## After implementation (large builds)

- **Explainer** — bundle the winning artifact, plan, and notes into one short summary doc. Say which unknowns were resolved and how.
- **Comprehension quiz before merge** — for a change the user must truly own, generate a short HTML (or plain-text) report of what changed and why, then **quiz the user on it.** Recognition is one more cheap catch for a lurking unknown before it ships.

## Claude Code features vs. normal-chat fallbacks

Treat these as *available when running inside Claude Code*, not as requirements. Fall back cleanly elsewhere.

- **AskUserQuestion** → focused questions with concrete options. Fallback: paste the same options in chat and ask the user to pick.
- **Goal mode (`/goal`, `Goal`, or equivalent)** → capture "what final good looks like" and the acceptance evidence before exploration. Fallback: write a one-line `Goal frame` yourself, mark it as inferred, and ask the user to correct it when available.
- **No live user available** → emit a `Deferred Questions` table: `Question | Options | Default assumption if unanswered | Why it matters | What would change`. Continue only under the most conservative reversible default. If no reversible default exists, stop at findings.
- **Plan mode / ExitPlanMode** → produce and review a plan without writing code. Fallback: a `plan.md` or a chat message the user explicitly approves.
- **Artifacts / HTML files** → use *when* the decision is visual or interactive (design variants, UX flows, dashboard shapes). For non-visual comparison (API shape, interface signatures, tradeoff summary), plain text or code snippets are the right medium — don't force HTML.

## Guiding principle

Prefer cheap discovery before expensive implementation. The win is not more process; it is fewer wrong turns.
