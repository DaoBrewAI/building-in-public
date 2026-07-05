# Techniques — per-quadrant playbook and workflow templates

Expanded guidance for each move in `SKILL.md`. Toolbox, not a checklist — pull only the section you need for the current task.

---

## 0. Establish the goal and user's starting point

Capture the goal shape plus the five starting-point fields from `SKILL.md`. If live asking is unavailable, infer them from the prompt and mark each inferred field as an assumption.

**Goal frame:** what final good looks like, what evidence would prove it, and what would still be out of scope.

**In Claude Code:** `AskUserQuestion`, 2–4 concrete options per question.

**Normal-chat fallback:**
> Before we dig in:
> (a) what should the final good result look like, and what evidence would prove it?
> (b) what's your current hypothesis for the fix?
> (c) how well do you know this codebase — first time, occasional, deep?
> (d) what constraints are you sure of?
> (e) what do you suspect but haven't verified?

**Autonomous fallback:** do not block. Write:

| Field | Inferred value | Confidence | Would ask if live |
|---|---|---|---|

---

## 1. Project scan — inspect the real surface

Ground everything downstream in what actually exists. Skim, don't deep-read.

What to look at:
- directory structure of the affected area
- public interfaces, types, schemas
- adjacent tests (they codify invariants)
- READMEs, ADRs, config
- existing patterns for similar work

**Do not invent generic blindspots before looking at the code.** Textbook blindspots waste the user's time; grounded ones save it.

---

## 2. Large-build Unknowns Map

Use this table for large builds. For medium diagnostics, skip this section and use `2a. Medium diagnostic contract` instead. The table is compact: every open item is tagged with a quadrant and a resolving move.

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|

- **Owner** = who resolves it: agent / user / reference / prototype.
- **Prioritize** items whose answer changes architecture, data model, API/interface shape, UX flow, dependencies, or an irreversible choice.
- **Skip** items whose answer wouldn't change what you build.

Update as items resolve. This *is* the state of the discovery phase.

---

## 2a. Medium diagnostic contract

Use this instead of a full Unknowns Map for ambiguous bugs, root-cause hunts, and read-only investigations.

Return exactly these sections:

1. **Goal frame** — inferred or user-stated final state, acceptance evidence, and out-of-scope boundary.
2. **Ranked hypotheses** — max 3 rows.
3. **Decisive discriminators** — one test/check per hypothesis.
4. **Blindspots** — max 3 rows, each classified as bug-likely / architecture risk / likely by design / roadmap gap.
5. **Deferred questions** — max 4 architecture-changing questions with options, when no live user answer is available.

Template:

| Rank | Hypothesis | Evidence | Decisive discriminator | What would change my mind | Status |
|---|---|---|---|---|---|

Do not include full quadrant tables, `implementation-notes.md`, plan mode, prototypes, explainers, or quizzes unless the user asks or the task becomes a large build.

---

## 3. Close KNOWN KNOWNS — keep them explicit

Facts stated in the prompt or already visible in the codebase. The failure mode is losing them, not discovering them.

- Restate them in the plan and `implementation-notes.md`.
- Reference them in prompts to hold context.

**Examples:**
- "Runtime is Node 22." (from `package.json`)
- "Sessions live in `sessions` table with 30-day TTL." (from schema)
- "We support only Postgres 15+." (from ADR)

---

## 4. Close KNOWN UNKNOWNS — focused questions

Ask only questions whose answer would change:
- architecture / module boundaries
- data model / persistence
- API / interface shape
- UX flow
- dependencies (adding a library, changing a runtime)
- an irreversible choice (migration, public contract)

Skip anything cosmetic or reversible.

**In Claude Code:** `AskUserQuestion`, 2–4 concrete options per question.

**Normal-chat fallback template:**
> Two decisions that would change the design — pick one for each.
> 1. Deletes: (a) cascade to children, (b) soft-delete, (c) block if referenced.
> 2. Session store: (a) DB table, (b) signed cookie, (c) Redis.

**Example of a question worth asking:**
> Multi-tenant isolation: (a) schema-per-tenant, (b) row-level with `tenant_id`, or (c) shared tables with app-level filtering? This choice cascades into every query.

**Example of a question NOT worth asking:**
> What color should the button be? (Cosmetic, reversible — pick a reasonable default and move on.)

A few decisive questions beat a long questionnaire.

---

## 5. Close UNKNOWN KNOWNS — show, don't ask

The user knows implicitly but can't specify cold. Recognition beats specification. Pick the medium by what's being decided.

### 5a. Concept / scope brainstorm — intervention options

For "where do we intervene?" questions. Enumerate cheapest to most ambitious.

**Template — "10 intervention points, cheapest to most ambitious":**
> 10 ways to address <symptom>, ordered from cheapest to most ambitious. For each: what it takes, what it costs, what it doesn't fix.
> 1. Change one config value.
> 2. Add a feature flag around existing behavior.
> 3. Patch the specific call site.
> 4. Add a small helper and switch a few callers.
> 5. Introduce a new abstraction limited to this area.
> 6. Refactor the module.
> 7. Rewrite the module.
> 8. Extract a service.
> 9. Change the schema/contract and migrate callers.
> 10. Rebuild the subsystem.

Have the user pick a range ("options 2–4 look right; skip 6+"). That range becomes the scope.

### 5b. Codebase-search brainstorm

Before designing something new, search the repo for existing patterns and comparable implementations. Present 3–5 hits and ask which behavior to match.

**Template:**
> Here are 3 places we already do something like <X> — read the linked functions and pick which behavior this new code should match, or say "none of these, do it differently."
> 1. `path/a.ts:fn` — behavior A
> 2. `path/b.ts:fn` — behavior B
> 3. `path/c.ts:fn` — behavior C

### 5c. Prototype variants — when recognition/taste is the blocker

**Only** reach for prototype variants when the blocker is visual, interactive, or taste-heavy. Otherwise it's overkill and slower than sketches.

Generate **3–5 meaningfully different** directions — not variations on one idea. The spread is the point; it covers the space the user hasn't articulated.

**Visual / interactive (right medium: HTML):**
- Self-contained HTML **Artifacts** (Claude Code) or standalone `.html` files.
- Radically different bets: e.g., dense-data table, calendar-first, kanban, timeline, chat-thread. Not five color palettes.
- Build toward the direction the user picks.

**API / interface shape (right medium: plain text):**
- Side-by-side signature or schema sketches — TypeScript interfaces, OpenAPI stubs, function signatures, table schemas.
- Compact. Don't render these as HTML.

**Approach / architecture (right medium: comparable code + tradeoff card):**
- Comparable-code pointers ("here are three existing patterns; which should this match?").
- Tradeoff cards: choice vs. cost vs. benefit vs. reversibility, in a small table.

---

## 6. Close UNKNOWN UNKNOWNS — blindspot pass

The dangerous quadrant. You cannot list your own blind spots — enumerate against the real project.

**Template (files must be read first):**
> I'm about to <do X>. BEFORE writing anything:
> 1. Read: <specific files, tests, docs, schemas>.
> 2. Then tell me what I'm not considering — existing conventions, coupling, hidden constraints, invariants, edge cases, places this will ripple.
> 3. Tie every finding to a specific file, behavior, dependency, or unanswered product decision. No generic textbook blindspots.

**Concrete example (unfamiliar auth code):**
> Adding a new auth provider. First read `src/auth/`, `middleware/session*`, and the tests in `test/auth/`. Then: what should I be aware of — token refresh, provider registration order, existing session assumptions, test fixture patterns? Tie each finding to a specific file.

**Down-rank before presenting:** candidate blindspots are not automatically bugs. Classify each one:

- **Bug-likely** — contradicts tests, docs, schemas, call-site expectations, or observed behavior.
- **Architecture risk** — plausible hidden coupling or invariant; needs verification.
- **Likely by design** — repeated pattern, named abstraction, docs/tests encode it, or no caller expects the missing behavior.
- **Roadmap gap** — not implemented yet, but no current code path requires it.

Present `likely by design` and `roadmap gap` as assumptions to verify, not as bugs. In medium diagnostics, show at most 3 blindspots after down-ranking.

**After the pass:** present the list, confirm with the user if available, record it in the notes only for large builds / implementation work. If it surfaces an architecture-shaping unknown, route it back to the map (as a new question or a prototype item). Do NOT proceed to the plan yet.

---

## 7. References — read before you design

Prefer **source code** where behavior matters. Other media are useful for other purposes.

- **Source code** — behavior, edge cases, conventions.
- **Docs / ADRs** — intent, historical decisions, invariants.
- **Diagrams** — component relationships, data flow.
- **Screenshots** — end-user state (not behavior).
- **Websites / external references** — patterns, competitor behavior, standards.

**Template:**
> What's the closest existing thing to what you want — in this repo, another repo, a doc, a diagram, or a product? Point me at it; I'll read it before designing.

Read the reference *before* designing so you don't silently default to industry-generic.

---

## 8. Plan — after the map is resolved enough

Write the plan when remaining unknowns are small enough to absorb during the build.

**In Claude Code:** `plan mode` / `ExitPlanMode`.

**Fallback:** write the plan as a message or a `plan.md` and get explicit user approval.

**Weight the plan** toward parts most expensive to change late:
- data models
- type / interface shapes
- user-facing surface

Skim the mechanical parts. Set the specificity dial: concrete where the map is closed, deliberately open where the model's judgment should win.

---

## 9. Seed and maintain the implementation notes

Use `templates/implementation-notes.md` only for large builds or implementation work. Do not create it for medium read-only diagnostics. Fill user starting point, starting context, Unknowns Map, and blindspot findings before the first line of real code. Append decisions and deviations as they happen.

---

## 10. Hand off to a fresh implementation session (large builds)

Once the map is resolved and the plan is approved, start a fresh session for implementation. Carry a lean bundle:

- distilled prompt (post-discovery, specificity dial set)
- selected artifacts (chosen prototype, sample data, chosen intervention range)
- references (which files/docs to read first)
- the approved plan
- `implementation-notes.md` seeded with starting point, surviving open questions, and blindspot findings

Discovery transcripts bloat context and dilute signal. A clean start with the concentrated bundle keeps the implementation agent focused.

---

## 11. After implementation

- **Explainer.** Bundle the winning artifact, plan, and notes into one short summary doc — handoff and review surface. Include which unknowns were resolved and how.
- **Comprehension quiz before merge.** For a change the user must truly own, generate a short HTML (or plain-text) report of what changed and why, then quiz the user on it. Recognition is one more cheap catch for a lurking unknown.

---

## Guiding principle

> Every explainer, brainstorm, interview, prototype, and reference is a cheap way to find out what you didn't know before it gets expensive to fix.
