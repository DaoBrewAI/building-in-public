# finding-your-unknowns

Use a coding agent to surface the task unknowns that would otherwise become mid-build guesses.

This Claude Code skill is inspired by Thariq Shihipar's X article ["A Field Guide to Fable: Finding Your Unknowns"](https://x.com/trq212/status/2073100352921215386?s=46). The core idea: prompts and context are the map; the real codebase, constraints, and user intent are the territory.

## What You Get

- **Goal frame**: what "done" looks like, what would prove it, and what is out of scope.
- **Scaled discovery**: skip trivial edits, keep medium diagnostics compact, and reserve the full Unknowns Map for large builds.
- **Medium diagnostic contract**: ranked hypotheses, decisive discriminators, down-ranked blindspots, and deferred questions when the user cannot answer live.
- **Large-build workflow**: the four-quadrant map of known knowns / known unknowns / unknown knowns / unknown unknowns, plus implementation notes and handoff guidance.

The practical difference: the agent should not jump from a vague report to one confident fix. It should first name the plausible branches, identify the cheapest check that kills each branch, and ask only the questions that would change the architecture or implementation.

## When To Use It

Use it when the request has meaningful uncertainty:

- an ambiguous bug report,
- an unfamiliar repo or module,
- an architecture / data model / API decision,
- a UX or taste-heavy implementation,
- a long-horizon multi-file build,
- any task where "what good looks like" is not crisp yet.

Do not use it for trivial, well-specified edits.

## How It Works

The skill treats uncertainty as four different categories, each with a different resolving move:

| Quadrant | Meaning | Resolving move |
|---|---|---|
| Known knowns | Facts already stated or visible in the repo | Keep them explicit and referenced |
| Known unknowns | Questions the user already knows are open | Ask focused questions with concrete options |
| Unknown knowns | Taste, product intuition, or "I'll know it when I see it" knowledge | Show options, prototypes, interface sketches, or comparable code |
| Unknown unknowns | Constraints nobody named yet | Run a repo-grounded blindspot pass before building |

For medium bug investigations, it deliberately avoids the full quadrant ceremony. It uses a smaller output: Goal frame -> ranked hypotheses -> discriminating checks -> down-ranked blindspots -> deferred questions.

## Requirements

- Claude Code with custom skills enabled.
- A task with enough ambiguity to justify a discovery pass.
- Optional but useful: access to the relevant repo files, tests, docs, schemas, or product references.

## Install

Copy only the runtime skill files:

```bash
mkdir -p ~/.claude/skills/finding-your-unknowns
cp finding-your-unknowns/SKILL.md ~/.claude/skills/finding-your-unknowns/
cp -R finding-your-unknowns/templates ~/.claude/skills/finding-your-unknowns/
```

Or use the packaged skill file if your Claude Code setup imports `.skill` bundles:

```text
finding-your-unknowns.skill
```

Restart Claude Code or reload skills after installing.

## Usage

The skill should trigger automatically on uncertain coding tasks. You can also invoke it directly:

```text
Use $finding-your-unknowns to investigate this ambiguous bug report:
"memory ingest appears to run, but the reasoner never sees the memory rows."
```

For a medium diagnostic, the intended output shape is:

```markdown
## Goal frame
Done looks like...
Evidence that would prove it...

## Ranked hypotheses
| Rank | Hypothesis | Evidence | Decisive discriminator | What would change my mind |

## Down-ranked blindspots
- Bug-likely / architecture risk / likely by design / roadmap gap

## Deferred questions
| Question | Options | Default assumption | Why it matters |
```

## Typical Flow

For an ambiguous bug:

1. Infer or ask for the Goal frame.
2. Read the smallest useful repo surface.
3. Keep up to 3 ranked hypotheses alive.
4. Attach one decisive discriminator to each hypothesis.
5. Down-rank findings that are likely by design or not-built-yet roadmap gaps.
6. Continue under reversible assumptions, and emit deferred questions if no live user is available.

For a large build:

1. Capture the user's starting point and what "good" looks like.
2. Build the four-quadrant Unknowns Map.
3. Resolve each item with the lightest move.
4. Plan only after the architecture-changing unknowns are closed or explicitly deferred.
5. Keep `implementation-notes.md` live during implementation.

## Trial: Ambiguous Memory Pipeline Bug

This skill was tested on a real, read-only diagnostic task in a large unfamiliar TypeScript repo. The test case is included here because the skill's value is not just theoretical: it changed the shape of the investigation even when the final root cause was findable without it.

The user report was intentionally vague:

```text
the CTO's memory pipeline won't connect to the reasoner
```

The repo contained three relevant concepts:

- a memory ingest path that writes signals,
- a database-backed signal store,
- a reasoner that reads those signals.

The task was not to patch code. It was to identify the most likely failure modes and the evidence needed to distinguish them.

Scoring below is a reviewer score for the skill's behavior on this task, not a claim that the model became more "correct" in the abstract. The reviewer weighted: answer correctness, compactness, ability to keep multiple hypotheses alive, quality of discriminating checks, handling of likely-by-design findings, and quality of user-facing questions.

### Trial 1: Before the skill tightening

The skill found the same primary root cause as a competent baseline. On this particular bug, it did not improve raw answer correctness.

It did add value:

- front-loaded ambiguity instead of assuming one interpretation,
- kept multiple hypotheses alive,
- proposed decisive checks,
- surfaced an extra code concern,
- separated a real bug from a not-built-yet roadmap item,
- produced concrete questions that would collapse the remaining uncertainty.

But it was too expensive for a medium task:

- it produced a full Unknowns Map and quadrant tables,
- one blindspot was probably intentional design, not a bug,
- the live-user question flow could not be used in an autonomous run,
- the real differentiator was buried under generic due diligence.

Reviewer score after Trial 1: **6.8 / 10**.

### What Changed

The skill was revised around four rules:

- Start with the **Goal frame**: final state, acceptance evidence, out-of-scope boundary.
- For medium diagnostics, output only ranked hypotheses, discriminators, down-ranked blindspots, and deferred questions.
- Classify blindspots before presenting them: `bug-likely`, `architecture risk`, `likely by design`, or `roadmap gap`.
- If no live user is available, continue with conservative reversible assumptions and emit deferred questions instead of blocking.

### Trial 2: After the Goal-aware revision

The same style of report was re-run:

```text
the CTO's memory pipeline won't connect to the reasoner
```

The revised skill stayed in medium diagnostic mode. It produced:

- a Goal frame with concrete acceptance evidence,
- 3 ranked hypotheses,
- one discriminator per hypothesis,
- down-ranked blindspots instead of alarmist bug claims,
- deferred questions for the missing live user context.

The highest-ranked hypothesis was a store mismatch: memory ingest wrote to Postgres while the reasoner could silently fall back to SQLite unless the launch environment set the correct graph-store configuration. The report also separated that from two different issues: whether ingest had ever been triggered, and whether enrichment axes were a later roadmap gap rather than a connection failure.

Reviewer score after Trial 2: **8.4 / 10**.

The score improved because the skill became more binding about scale: medium diagnostics stayed medium. The output got sharper around the parts that actually changed the investigation: Goal frame, ranked hypotheses, discriminators, down-ranked blindspots, and deferred questions.

The remaining cost: the agent still read fairly deeply. This skill should not be sold as guaranteed token reduction on every first pass. Its stronger claim is narrower and more useful: it reduces wasted investigation and rework by keeping the agent from turning early uncertainty into confident guesses.

## Why This Matters

This skill is not trying to make agents "think harder" in the abstract.

It makes them spend a small amount of effort up front to answer:

- What are we actually trying to prove?
- Which hypotheses are plausible?
- What single check would kill each hypothesis?
- Which apparent problems are real bugs, and which are likely by design?
- What must we ask the user, if we cannot safely infer it?

That is the difference between a useful investigation and a beautifully written guess.

## FAQ

### Does this reduce token usage?

Not automatically. For small tasks, the skill should skip itself. For medium diagnostics, it should reduce process overhead by avoiding the full Unknowns Map. For large builds, it may spend more tokens up front to avoid more expensive rebuilds later.

### Is this a replacement for code review?

No. It happens before and during implementation. Its job is to surface uncertainty early; review still checks whether the final code is correct.

### Why include the X article link in the README but not inside the skill?

The README is public context for humans. The skill itself stays lean so the agent spends context on reusable operating instructions, not provenance.
