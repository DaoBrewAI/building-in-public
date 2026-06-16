# Codex Loop Engineering

> A repo-first setup for turning Codex from a one-turn assistant into a bounded, evidence-driven engineering loop.

Loop engineering is not "write a bigger prompt." It is the practice of designing the system that prompts, checks, records, and re-prompts the agent. In Codex, the smallest useful version looks like this:

```text
Goal -> tracker -> checkpoint -> verification -> state update -> continue or stop
```

Use this when the work is bigger than one prompt, but still has a clear finish line: migrations, refactors, flaky-test hunts, performance tuning, prototype hardening, launch asset cleanup, or multi-phase implementation work.

## Loop Engineering Principles

The useful version of loop engineering comes down to a few repeatable design choices:

1. **Design the loop, not just the prompt.** The agent should be prompted by a system of files, checks, and continuation rules, not only by your next chat message.
2. **Keep state outside the chat.** Goals, trackers, constraints, and handoffs belong in the repo so another Codex session can continue from the same truth.
3. **Make progress observable.** A loop needs tests, builds, screenshots, benchmark output, review notes, or artifacts that tell Codex whether the last action worked.
4. **Use checkpoints.** Long work should be split into small, committable slices with a clear verification step after each one.
5. **Define stop conditions.** Success, blocker, budget exhaustion, credential needs, risky external actions, and human approval gates must be explicit.
6. **Preserve human control.** Loop engineering is not unattended production autonomy. It is bounded delegation with evidence and escape hatches.

## The Core Idea

A normal prompt says:

```text
Do this next thing.
```

A Codex loop says:

```text
Keep working toward this outcome until the evidence says it is done, blocked, or out of budget.
```

That shift changes your job. You stop manually saying "continue," "run tests," "try the next fix," and "update the plan." Instead, you design a repo contract that tells Codex:

- what goal to pursue
- what files to read first
- how the work is split into phases
- what constraints must not be violated
- what evidence proves progress
- when to stop and ask for human input
- how to leave the next session enough state to continue

## What Your Initial Setup Needs

Your three instincts are the right foundation:

1. **A goal**: the durable objective Codex should keep in view.
2. **A tracker**: a multi-phase plan with checkboxes, status, and current next action.
3. **Constraints**: architecture, product, safety, repo, and workflow boundaries.

The pieces people usually forget are:

4. **Context packet**: the exact files, docs, branches, issues, logs, screenshots, or examples Codex must read before acting.
5. **Verification surface**: tests, builds, screenshots, benchmark output, generated artifacts, or review checks that prove the loop is improving reality.
6. **Handoff state**: a short file that says what just happened, what is next, what is blocked, and what commands were last run.
7. **Stop conditions**: clear rules for success, blocker, budget exhaustion, missing credentials, or human approval.
8. **Git checkpoints**: small commits after coherent progress so the loop can roll forward safely.

## Recommended Repo Layout

Create a small loop folder inside the project you want Codex to operate on:

```text
docs/loop/
  goal.md
  tracker.md
  constraints.md
  handoff.md
```

For larger projects, `docs/design/` or `docs/plans/` is fine. The exact folder name matters less than one rule: Codex should always know which files are the source of truth.

## File 1: Goal

`docs/loop/goal.md`

```md
# Goal

## Objective

Complete <specific outcome>.

## Done When

- <evidence that proves the outcome>
- <tests/builds/artifacts that must pass or exist>
- <user-facing behavior that must be true>

## Non-Goals

- Do not <out-of-scope change>.
- Do not <risky expansion>.

## Read First

- <file, doc, issue, screenshot, API spec, design note>
- <tracker file>
- <constraints file>
```

A good goal is narrow enough to audit, but broad enough for Codex to choose the next useful action.

## File 2: Tracker

`docs/loop/tracker.md`

```md
# Loop Tracker

## Status Legend

- [ ] not started
- [~] in progress
- [x] complete
- [!] blocked

## Phases

| Phase | Status | Goal | Verification | Notes |
| --- | --- | --- | --- | --- |
| 1 | [ ] | Map current state | Link to files inspected and risks found | |
| 2 | [ ] | Implement first coherent slice | Tests/build pass | |
| 3 | [ ] | Harden edge cases | Targeted regression coverage | |
| 4 | [ ] | Final review and docs | Full verification checklist | |

## Current Next Action

Start with Phase 1. Update this section after every checkpoint.
```

The tracker is the loop's memory. It prevents Codex from rediscovering the plan every turn and gives you a dashboard for the video.

## File 3: Constraints

`docs/loop/constraints.md`

```md
# Constraints

## Product Constraints

- Preserve <user flow, API contract, visual behavior, or launch narrative>.

## Engineering Constraints

- Follow existing repo patterns before adding new abstractions.
- Keep commits scoped to one coherent checkpoint.
- Do not touch unrelated files.
- Prefer tests and verification over claims of completion.

## Safety Constraints

- Stop before using production credentials, deleting user data, changing billing, or deploying.
- Ask for approval before irreversible external actions.

## Budget Constraints

- Stop after <time, token, cost, or attempt limit> if the goal is not yet verifiable.
```

Constraints are not just "rules." They are the guardrails that let Codex keep moving without you babysitting every decision.

## File 4: Handoff

`docs/loop/handoff.md`

````md
# Loop Handoff

## Current State

- Branch:
- Last checkpoint:
- Last verification:
- Known risks:

## Next Step

Execute the next unchecked item in `docs/loop/tracker.md`.

## Commands Already Run

```bash
# paste recent verification commands here
```

## Blockers

- None, or describe exactly what input is needed.

## Auto-Chain Permission

auto_chain_next_session: false

If set to true and the Codex environment supports creating the next session, Codex may create a project-local continuation session after it:

- updates tracker and handoff
- runs verification
- commits and pushes the checkpoint
- confirms unchecked work remains
- confirms no blocker needs human approval, credentials, or external data
````

The handoff is what lets the loop survive context windows, app restarts, or a new Codex thread.

## Starting the Codex Goal

If Codex Goals are available, use `/goal` for the durable objective:

```text
/goal Complete <objective> verified by <specific evidence> while preserving <constraints>.

First read:
- docs/loop/goal.md
- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md

Then execute the next unchecked tracker item. Work in coherent checkpoints.
After each checkpoint, run verification, update tracker and handoff, inspect the diff,
commit the checkpoint, and continue only if the next step is still within scope.

Stop if success is verified, a blocker needs human input, or the budget is reached.
```

If `/goal` is not visible, enable Codex Goals:

```bash
codex features enable goals
```

Or add this to Codex config:

```toml
[features]
goals = true
```

## Checkpoint Loop

Every Codex iteration should follow the same closure pattern:

1. Read the goal, tracker, constraints, and handoff.
2. Pick the next unchecked tracker item.
3. Make the smallest coherent change.
4. Run the verification named in the tracker.
5. Update the tracker with status and evidence.
6. Update the handoff with next action and blockers.
7. Run `git diff --check`.
8. Commit the checkpoint.
9. Continue only if unchecked work remains and no stop condition fired.

This is the practical loop:

```text
plan state -> act -> observe -> record -> decide
```

## Auto-Chain Sessions

For long multi-phase work, you can allow Codex to create the next session after a clean checkpoint. Keep this permission explicit in the handoff:

```md
## Auto-Chain Permission

auto_chain_next_session: true

Rules:
- Do not fork.
- Do not paste long plans into the next Goal.
- Use a short Goal that points to the handoff and tracker.
- Update tracker and handoff before creating the next session.
- Commit and push before creating the next session.
- Stop if a blocker needs human approval, external credentials, or external data.
```

Use a short continuation goal:

```text
Continue <Project Name> in <repo path> on branch <branch>.

First read:
- docs/loop/handoff.md
- docs/loop/tracker.md
- docs/loop/constraints.md

Then execute the next unchecked loop exactly as documented there. Keep the commit
scoped, run verification, update tracker and handoff, commit, and push.
```

Auto-chain is optional. The real principle is that the repo holds the state, not the chat transcript.

## Video Narrative

Here is a clean way to explain it on camera:

```text
Loop engineering with Codex is not about writing a magical prompt.
It is about setting up a small operating system around the agent.

I need three core files:
first, a goal, so Codex knows the durable outcome;
second, a tracker, so multi-phase work has state;
third, constraints, so the agent knows what not to break.

Then I add two things that make it actually work:
verification, so Codex has evidence instead of vibes;
and a handoff, so the next session can continue without me pasting a huge plan.

The loop is simple:
read the state, do the next checkpoint, verify it, update the state,
commit it, then either continue or stop with a real blocker.

That is how I set up loop engineering with Codex.
```

## Quick Setup Script

Run this from the repo root of the project you want Codex to operate on:

```bash
mkdir -p docs/loop

cat > docs/loop/goal.md <<'EOF'
# Goal

## Objective

Complete <specific outcome>.

## Done When

- <specific evidence>

## Non-Goals

- Do not <out-of-scope change>.

## Read First

- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md
EOF

cat > docs/loop/tracker.md <<'EOF'
# Loop Tracker

| Phase | Status | Goal | Verification | Notes |
| --- | --- | --- | --- | --- |
| 1 | [ ] | Map current state | Evidence links added | |
| 2 | [ ] | Implement first coherent slice | Tests/build pass | |
| 3 | [ ] | Harden edge cases | Regression coverage | |
| 4 | [ ] | Final review and docs | Full checklist pass | |

## Current Next Action

Start with Phase 1.
EOF

cat > docs/loop/constraints.md <<'EOF'
# Constraints

- Follow existing repo patterns.
- Keep commits scoped to one coherent checkpoint.
- Do not touch unrelated files.
- Run verification before claiming completion.
- Stop before credentials, production data, deployments, or destructive actions.
EOF

cat > docs/loop/handoff.md <<'EOF'
# Loop Handoff

## Current State

- Branch:
- Last checkpoint:
- Last verification:
- Known risks:

## Next Step

Execute the next unchecked item in `docs/loop/tracker.md`.

## Blockers

- None.

## Auto-Chain Permission

auto_chain_next_session: false
EOF

echo "Codex loop files created in docs/loop/"
```

## Further Reading

- [Loop Engineering - Addy Osmani](https://addyosmani.com/blog/loop-engineering/)
- [Follow a goal - OpenAI Codex docs](https://developers.openai.com/codex/use-cases/follow-goals)
- [Using Goals in Codex - OpenAI Cookbook](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)
- [Codex best practices - OpenAI Developers](https://developers.openai.com/codex/learn/best-practices)
