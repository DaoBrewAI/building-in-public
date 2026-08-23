# Techniques - per-quadrant playbook

Load this file only when `SKILL.md` says a concrete technique is needed. Do not
run every section.

## 0. Establish The Goal Frame

Use the active Codex Goal or `docs/loop/goal.md` when present. Otherwise infer
the goal frame and mark it as inferred.

```markdown
## Goal frame
- Done looks like:
- Evidence that proves it:
- Out of scope:
- Current hypothesis:
- Known constraints:
- Suspicions not yet verified:
```

If live clarification is possible, ask only questions that change architecture,
data model, API shape, UX flow, dependencies, or irreversible choices. In Codex
Plan mode, use `request_user_input` if available. Otherwise ask in chat with
2-4 concrete options.

Autonomous fallback:

| Field | Inferred value | Confidence | Would ask if live |
|---|---|---|---|

## 1. Project Scan

Ground everything downstream in the real project:

- affected directory structure,
- public interfaces, types, schemas,
- adjacent tests and fixtures,
- README / ADR / config,
- existing implementations that resemble the requested work.

Do not invent generic blindspots before reading code.

## 2. Medium Diagnostic Contract

Use this for ambiguous bugs, root-cause hunts, and read-only investigations.
Return exactly these sections unless the user asks for more:

1. Goal frame.
2. Ranked hypotheses, max 3.
3. Decisive discriminators, one per hypothesis.
4. Blindspots, max 3 after down-ranking.
5. Deferred questions, max 4 if no live user answer is available.

Template:

| Rank | Hypothesis | Evidence | Decisive discriminator | What would change my mind | Status |
|---|---|---|---|---|---|

Do not include full quadrant tables, prototypes, implementation notes, or loop
handoffs for medium diagnostics unless the task becomes a large build.

## 3. Large-Build Unknowns Map

Use this for multi-file builds, irreversible API/data decisions, taste-heavy
work, or repo-loop checkpoints with real ambiguity.

| Item | Quadrant | Evidence | Why it matters | Resolving move | Owner | Status |
|---|---|---|---|---|---|---|

Owner means agent / user / reference / prototype. Skip anything whose answer
would not change the build.

## 4. Known Knowns

Known knowns are facts from the prompt, active Goal, loop files, code, tests, or
docs. The failure mode is losing them.

Examples:

- Runtime is Node 22 from `package.json`.
- The checkpoint is "fix flaky import" from `docs/loop/tracker.md`.
- The constraint says no schema migration in this phase.

Carry these into the plan, notes, or handoff.

## 5. Known Unknowns

Ask only questions whose answer would change the build.

Good:

```text
Session deletion behavior:
a) cascade child rows
b) soft-delete sessions
c) block deletion while referenced

This changes the migration and API contract.
```

Bad:

```text
What color should the button be?
```

Cosmetic and reversible questions should be handled with a reasonable default.

## 6. Unknown Knowns

The user often recognizes the right answer faster than they can specify it.
Show options.

### Scope brainstorm

Use when the shape of the fix is uncertain.

```text
10 intervention points, cheapest to most ambitious.
For each: what it takes, what it costs, and what it does not fix.
```

### Codebase-search brainstorm

Use when the repo likely already has a pattern.

```text
Here are 3 places we already do something like <X>.
Pick which behavior to match, or say none.
```

### Prototype or artifact variants

Use only when the blocker is visual, interactive, or taste-heavy. Create 3-5
meaningfully different directions. For API or architecture decisions, use
interface sketches or tradeoff cards instead of HTML.

## 7. Unknown Unknowns

You cannot list blindspots from pure imagination. Read the relevant surface,
then enumerate what the prompt did not name.

Blindspot prompt:

```text
Before implementing <X>, read <specific files/tests/docs>.
Then list constraints, conventions, coupling, invariants, edge cases, or ripple
effects I may be missing. Tie every finding to a file, behavior, dependency, or
unanswered product decision.
```

Down-rank before presenting:

- `bug-likely`: contradicts tests, docs, schemas, call-site expectations, or
  observed behavior.
- `architecture risk`: plausible hidden coupling or invariant; needs checking.
- `likely by design`: repeated pattern, named abstraction, docs/tests encode it,
  or no caller expects the missing behavior.
- `roadmap gap`: not built yet, but no current code path requires it.

Likely-by-design and roadmap-gap items are assumptions to verify, not bug claims.

## 8. Codex Loop Handoff Snippet

When paired with `$codex-loop-engineering`, put this compact block in
`docs/loop/handoff.md` before continuation:

```markdown
## Unknowns carried forward
- Goal frame:
- Resolved decisions:
- Conservative defaults:
- Deferred questions:
- Blindspots:
- Distilled continuation prompt:
```

If any deferred question changes architecture, data model, API shape, UX flow, or
an irreversible choice and has no reversible default, mark the loop blocked.

## 9. Implementation Notes

Use `templates/implementation-notes.md` for large builds and implementation work.
Do not create it for medium read-only diagnostics.

## 10. Explainer And Quiz

For changes the user must truly own, create a short explainer after
implementation: what changed, which unknowns were resolved, what remains risky,
and what to verify before merge. Use HTML only when the artifact is visual or
interactive; otherwise plain Markdown is enough.
