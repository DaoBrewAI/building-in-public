# finding-your-unknowns

A Codex skill for surfacing the task unknowns that usually turn into mid-build
guesses.

Inspired by Thariq Shihipar's X article ["A Field Guide to Fable: Finding Your
Unknowns"](https://x.com/trq212/status/2073100352921215386?s=46), this skill
treats prompts and context as the map, and the real codebase, constraints, user
intent, and runtime behavior as the territory.

## What It Does

`finding-your-unknowns` helps Codex decide what it does not know before it
commits to a plan:

- starts from the active Codex Goal, repo loop files, or an inferred goal frame;
- maps known knowns / known unknowns / unknown knowns / unknown unknowns;
- keeps medium diagnostics compact with ranked hypotheses and decisive tests;
- down-ranks blindspots that are likely by design or roadmap gaps;
- turns missing live-user context into deferred questions with reversible
  defaults;
- integrates with `codex-loop-engineering` by carrying unresolved assumptions
  into `docs/loop/handoff.md`.

It is not a heavier planning ritual. The useful part is forcing the agent to
keep plausible branches alive, run the cheapest discriminator for each branch,
and ask only the questions that would change the implementation.

## When To Use It

Use it for:

- ambiguous bug reports;
- unfamiliar repos or modules;
- architecture, data-model, API, or UX decisions;
- taste-heavy product work;
- long-running multi-file builds;
- Codex loop checkpoints where hidden constraints could derail the next phase.

Do not use it for trivial, well-specified edits.

## Install For Codex

Recommended for active development:

```bash
cd /path/to/building-in-public/finding-your-unknowns
bash install-codex-skill.sh
```

Portable copy install:

```bash
cd /path/to/building-in-public/finding-your-unknowns
bash install-codex-skill.sh copy
```

Restart or reload Codex after installing.

Use it with:

```text
Use $finding-your-unknowns to investigate this ambiguous bug report:
"memory ingest appears to run, but the reasoner never sees the memory rows."
```

With loop engineering:

```text
Use $codex-loop-engineering and $finding-your-unknowns.
Read docs/loop/goal.md, tracker.md, constraints.md, and handoff.md, then surface
the unknowns for the next unchecked tracker item before implementing.
```

## Output Shapes

Medium diagnostic:

```markdown
## Goal frame
## Ranked hypotheses
## Down-ranked blindspots
## Deferred questions
## Root-cause confidence
```

Large build or loop checkpoint:

```markdown
## Goal frame
## Unknowns Map
## Resolved decisions and defaults
## Plan
## Implementation notes / handoff updates
```

## Trial Result

The skill was tested on an intentionally vague read-only diagnostic in a large
TypeScript repo:

```text
the CTO's memory pipeline won't connect to the reasoner
```

A competent baseline and the skill-assisted run found the same primary root
cause, so the win was not raw correctness. The skill improved the investigation
shape: it kept three hypotheses alive, attached decisive discriminators,
separated a real bug from a not-built-yet roadmap item, and produced concrete
architecture-changing questions.

After tightening the skill around Goal frame, compact medium diagnostics,
down-ranked blindspots, and autonomous deferred questions, reviewer score moved
from **6.8 / 10** to **8.4 / 10** on the same style of task.

The honest claim: this does not guarantee lower token usage on every first pass.
It reduces wasted investigation and rework when a task contains real uncertainty.

## Claude Code

The same method can be adapted to Claude Code, but this folder is now written as
a Codex-native skill. Claude-specific packaging may use the `.skill` bundle.
