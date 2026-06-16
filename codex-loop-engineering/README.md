# Codex Loop Engineering

> A small installable setup for running repo-first loop engineering with Codex.

This folder gives you a simple way to turn a project repo into a Codex loop:

```text
goal -> tracker -> constraints -> handoff -> verify -> commit -> continue or stop
```

It is for long-running work where Codex should keep state in files instead of relying on a giant chat prompt.

## Easy Setup

Clone this repo:

```bash
git clone git@github.com:DaoBrewAI/building-in-public.git
```

From the repo you want Codex to work on, run:

```bash
bash /path/to/building-in-public/codex-loop-engineering/install.sh
```

Optional settings:

```bash
PROJECT_NAME="My Project" \
LOOP_DIR="docs/loop" \
AUTO_CHAIN=false \
bash /path/to/building-in-public/codex-loop-engineering/install.sh
```

The installer creates:

| File | Purpose |
| --- | --- |
| `docs/loop/goal.md` | The durable objective, done criteria, non-goals, and read-first context. |
| `docs/loop/tracker.md` | The multi-phase plan Codex updates after each checkpoint. |
| `docs/loop/constraints.md` | Product, engineering, safety, budget, and git boundaries. |
| `docs/loop/handoff.md` | The current state, last verification, blockers, and optional auto-chain permission. |

## Start Codex

After filling in `docs/loop/goal.md`, start Codex with a goal like this:

```text
/goal Complete the objective in docs/loop/goal.md.

First read:
- docs/loop/goal.md
- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md

Then execute the next unchecked tracker item. Work in coherent checkpoints.
After each checkpoint, run verification, update tracker and handoff, inspect the
diff, commit the checkpoint, and continue only if the next step is still in scope.

Stop when the goal is verified, a blocker needs human input, or the budget is reached.
```

## Complete Markdown Setup

Read or download the full setup file here:

- [`codex-auto-chain-session-handoff-setup.md`](./codex-auto-chain-session-handoff-setup.md)

It includes the full loop engineering model, file templates, auto-chain handoff rules, session closing checklist, and troubleshooting notes.

## When To Use This

Use this for:

- multi-phase implementation work
- refactors and migrations
- flaky-test or bug investigations
- prototype hardening
- launch asset cleanup
- work that needs verification after each checkpoint

Do not use this for a one-off edit. A normal Codex prompt is better for small tasks.

## Further Reading

- [Loop Engineering - Addy Osmani](https://addyosmani.com/blog/loop-engineering/)
- [Follow a goal - OpenAI Codex docs](https://developers.openai.com/codex/use-cases/follow-goals)
- [Using Goals in Codex - OpenAI Cookbook](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)
