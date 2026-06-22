# Codex Loop Engineering

> A Codex skill plus installable setup for running repo-first loop engineering.

This folder is both:

- an installable Codex skill: `SKILL.md`
- a loop-file installer: `install.sh`

It gives you a simple way to turn a project repo into a Codex loop:

```text
goal -> tracker -> constraints -> handoff -> verify -> commit -> continue or stop
```

It is for long-running work where Codex should keep state in files instead of relying on a giant chat prompt.

## Install The Skill

Clone this repo:

```bash
git clone git@github.com:DaoBrewAI/building-in-public.git
```

Recommended for active use:

```bash
cd /path/to/building-in-public/codex-loop-engineering
bash install-codex-skill.sh
```

Portable copy install:

```bash
cd /path/to/building-in-public/codex-loop-engineering
bash install-codex-skill.sh copy
```

Restart or reload Codex after installing.

Use it with:

```text
Use $codex-loop-engineering to continue the loop.
```

## Install Loop Files

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

## Quick Health Check

From a project repo with loop files:

```bash
python ~/.codex/skills/codex-loop-engineering/scripts/loop_doctor.py \
  --loop-dir docs/loop --json
```

The doctor is read-only. It summarizes missing files, current/next checkpoint clues, auto-chain state, recorded thread IDs, and stale-thread markers.

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

## Source Of Truth Stack

Loop engineering works best as three layers:

| Layer | Role | Source of truth |
| --- | --- | --- |
| Project loop files | The actual execution contract for the current project. | `docs/loop/{goal,tracker,constraints,handoff}.md` |
| Loop engineering starter | The reusable installer and operating manual. | `codex-loop-engineering/` |
| Memory | Personal preference recall only. | Codex memory may remind the agent of this pattern, but it must not be the only place the policy lives. |

If a future Codex skill exists, it should only automate this stack: read the repo loop files, validate them, create/verify continuation sessions, and update the files. The repo files still stay authoritative.

## Smoothest Setup

The smooth target is:

```text
repo loop files + this installer + one thin Codex skill
```

The skill should do the boring ceremony:

- detect the loop directory;
- read `goal.md`, `tracker.md`, `constraints.md`, and `handoff.md`;
- execute only the next unchecked checkpoint;
- run the verification named in the tracker;
- update tracker and handoff;
- create the next continuation only when auto-chain is enabled;
- verify the new thread before reporting it.

That keeps the project state inspectable in the repo while making the day-to-day user command as small as:

```text
Continue the loop.
```

## Continuation Session Verification

When auto-chain creates the next Codex session, a returned thread ID is not enough. Treat session creation as successful only after all of these pass:

1. `create_thread` returns a thread ID.
2. `list_threads` or `read_thread` can find that exact ID or exact title.
3. `set_thread_title` succeeds, or a follow-up `read_thread` confirms the title is already correct.
4. `read_thread` shows the first turn exists and is either `inProgress` or completed normally.
5. Only then write the thread ID into `tracker.md`, `handoff.md`, and the final response.

If the ID cannot be found, the title update fails repeatedly, or the thread is visible but never starts work, do not record it as the next session. Mark it as stale in the handoff, create one replacement session, verify the replacement, and record only the verified thread ID.

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
