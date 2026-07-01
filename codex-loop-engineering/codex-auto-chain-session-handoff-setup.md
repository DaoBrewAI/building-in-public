# Codex Auto-Chain Session Handoff Setup

> Complete markdown setup for repo-first loop engineering with Codex.

This setup lets a multi-phase Codex project continue across checkpoints and sessions without pasting long plans into each new prompt. It gives Codex a durable goal, a tracker, constraints, verification surfaces, and a handoff file.

The core loop can be linear or a dependency graph:

```text
read state -> execute ready checkpoint(s) -> verify -> update state -> commit -> continue or stop
```

## What This Is For

Use this when the task is bigger than one prompt, but still has a clear finish line:

- migrations
- refactors
- flaky-test hunts
- performance tuning
- prototype hardening
- launch asset cleanup
- multi-phase feature implementation
- research-to-artifact work with a concrete deliverable

Do not use it for a tiny one-off edit. Loop engineering is useful when the agent needs state, checkpoints, and verification.

## Loop Engineering Requirements

A useful Codex loop needs eight pieces:

1. **Goal**: the durable outcome Codex should keep in view.
2. **Tracker**: the multi-phase plan and current next action.
3. **Constraints**: product, engineering, safety, repo, and budget boundaries.
4. **Context packet**: exact files, docs, branches, logs, screenshots, examples, or issues to read first.
5. **Verification surface**: tests, builds, screenshots, benchmark output, generated artifacts, review checks, or source evidence.
6. **Handoff state**: what changed, what was verified, what remains, and what is blocked.
7. **Stop conditions**: done, blocked, budget exhausted, missing credentials, risky external action, or human approval needed.
8. **Git checkpoints**: scoped commits after coherent progress.

## Easy Install

Clone the public repo:

```bash
git clone git@github.com:DaoBrewAI/building-in-public.git
```

Install the Codex skill:

```bash
cd /path/to/building-in-public/codex-loop-engineering
bash install-codex-skill.sh
```

From the project repo where Codex should work, run:

```bash
bash /path/to/building-in-public/codex-loop-engineering/install.sh
```

Optional settings:

```bash
PROJECT_NAME="My Project" \
LOOP_DIR="docs/loop" \
AUTO_CHAIN=true \
bash /path/to/building-in-public/codex-loop-engineering/install.sh
```

`AUTO_CHAIN=true` is the default for multi-phase loop work. Use
`AUTO_CHAIN=false` only for one-shot loops that must not create a follow-on
Codex session.

If files already exist, the installer skips them. To regenerate the files, run:

```bash
OVERWRITE=true bash /path/to/building-in-public/codex-loop-engineering/install.sh
```

## Installed Layout

The installer creates this folder in your target project:

```text
docs/loop/
  goal.md
  tracker.md
  constraints.md
  handoff.md
```

You can rename the folder, but keep all loop state in committed repo files. The repo should be the source of truth, not the chat transcript.

## File 1: Goal

`docs/loop/goal.md` tells Codex what the loop is trying to complete.

```md
# Goal

## Objective

Complete <specific outcome>.

## Done When

- <evidence that proves the outcome>
- <tests, builds, screenshots, benchmarks, or artifacts that must pass or exist>
- <user-facing behavior that must be true>

## Non-Goals

- Do not <out-of-scope change>.
- Do not <risky expansion>.

## Read First

- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md
- <project-specific file, issue, log, screenshot, design note, or API spec>
```

A strong goal is narrow enough to audit, but broad enough for Codex to choose the next useful action.

## File 2: Tracker

`docs/loop/tracker.md` is the multi-phase plan and dashboard. It defaults to a
linear loop, but can become a DAG when the task naturally has independent lanes.

```md
# Loop Tracker

## Status Legend

- `[ ]` not started
- `[~]` in progress
- `[x]` complete
- `[!]` blocked

## Execution Model

Default: linear. Execute the next unchecked checkpoint.

Use a dependency graph / DAG only when the user context or project plan clearly
shows independent lanes. If the DAG shape is uncertain, ask the user before
opening parallel sessions.

## Checkpoint Checklist

- [ ] Phase 1: Map current state.
- [ ] Phase 2: Implement first coherent slice.
- [ ] Phase 3: Harden edge cases.
- [ ] Phase 4: Final review and docs.

## Dependency Graph

For a linear loop:

    Phase 1 -> Phase 2 -> Phase 3 -> Phase 4

For a DAG loop, list parallel-safe lanes and predecessor-gated lanes explicitly.

## Phases

| Phase | Status | Goal | Verification | Notes |
| --- | --- | --- | --- | --- |
| 1 | [ ] | Map current state | Evidence links added | |
| 2 | [ ] | Implement first coherent slice | Tests/build pass | |
| 3 | [ ] | Harden edge cases | Regression coverage | |
| 4 | [ ] | Final review and docs | Full checklist pass | |

## Current Next Action

Start with Phase 1. Update this section after every checkpoint.

## Evidence Log

| Checkpoint | Verification Run | Result | Notes |
| --- | --- | --- | --- |
| | | | |
```

The tracker prevents Codex from rediscovering the plan every turn.

## File 3: Constraints

`docs/loop/constraints.md` defines what Codex must preserve while it works.

```md
# Constraints

## Product Constraints

- Preserve <user flow, API contract, visual behavior, launch narrative, or public interface>.

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

## Git Constraints

- Commit only after verification.
- Keep commit messages specific to the checkpoint.
- Do not rewrite shared history unless the user explicitly asks.
```

Constraints are the guardrails that let Codex keep moving without constant human steering.

## File 4: Handoff

`docs/loop/handoff.md` is the continuation state for the next turn or next Codex session.

````md
# Loop Handoff

## Current State

- Branch:
- Last checkpoint:
- Last verification:
- Known risks:

## Next Step

Execute the next unchecked item in `docs/loop/tracker.md`.

## Execution Model

Default to the linear next unchecked checkpoint. If the tracker/handoff or user
context clearly shows independent lanes, use a DAG: open only lanes whose
dependencies are satisfied and that do not already have verified active or
completed threads. If unsure, ask before opening parallel sessions.

## Commands Already Run

```bash
# paste recent verification commands here
```

## Blockers

- None, or describe exactly what input is needed.

## Auto-Chain Permission

auto_chain_next_session: true

If true and the Codex environment supports creating the next session, Codex must
attempt to create a verified project-local continuation session after it:

- updates tracker and handoff
- runs verification
- commits and pushes only if the project constraints or user request require it
- confirms unchecked work remains
- confirms no blocker needs human approval, credentials, or external data
- treats "one checkpoint only" as an implementation boundary, not as a reason to
  skip creating the next session

For DAG loops, auto-chain only to ready lanes:

- do not create duplicate sessions for lanes that already have verified thread IDs
- do not create predecessor-gated successors until all dependencies are complete
- stop and ask the user when the dependency direction is unclear
````

The handoff is what lets the loop survive context windows, app restarts, or a new Codex thread.

## Where The Policy Lives

Use this stack:

1. **Repo loop files are authoritative.** The current project's `goal.md`, `tracker.md`, `constraints.md`, and `handoff.md` decide what the next session does.
2. **This starter is the reusable template.** Update `codex-loop-engineering/` when the operating model improves, then reinstall or copy the relevant sections into active projects.
3. **Memory is advisory.** Memory helps Codex remember Neo's preferences, but it should never be the only source of auto-chain policy.
4. **A skill can automate the workflow.** A future skill should be a thin executor around the repo files: validate state, run the close-out checklist, create and verify the next thread, and write the verified ID back. It should not replace the repo-local contract.

## Starting The Codex Goal

If Codex Goals are available, use `/goal` for the durable objective:

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

If `/goal` is not visible, enable Codex Goals:

```bash
codex features enable goals
```

Or add this to Codex config:

```toml
[features]
goals = true
```

## Checkpoint Rules

Each Codex checkpoint should close with the same routine:

1. Confirm the current tracker state.
2. Execute the next unchecked task.
3. Run the verification named in the tracker.
4. Update `docs/loop/tracker.md` with status and evidence.
5. Update `docs/loop/handoff.md` with the next step, last verification, and blockers.
6. Run `git diff --check`.
7. Inspect the diff.
8. Commit only when allowed or required by the current project.
9. If unchecked work remains and no stop condition fired, create and verify the
   next continuation session before closing.

## Auto-Chain Sessions

For long multi-phase work, auto-chain is the default close-out: one Codex
session should create the next verified continuation session after a clean
checkpoint when unchecked work remains. Disable it only when the user or loop
explicitly says to stop after the checkpoint.

Record the policy in `docs/loop/handoff.md`:

```md
## Auto-Chain Permission

auto_chain_next_session: true

Rules:
- Do not fork.
- Do not paste long plans into the next Goal.
- Use a short Goal that points to this handoff file and the tracker.
- Preserve explicit session settings the user requires, such as model,
  reasoning effort, service tier, or mode. Pass exposed settings directly to
  `create_thread`; for example, extra high thinking is `thinking: "xhigh"`.
- Update tracker and handoff before creating the next session.
- Commit and push only when the project constraints or user request require it.
- Stop if a blocker needs human approval, external credentials, or external data.
- Treat "one checkpoint only" as one implementation slice, not as permission to
  skip creating the next session.
```

Use a short continuation goal:

```text
Continue <Project Name> in <repo path> on branch <branch>.

First read:
- docs/loop/handoff.md
- docs/loop/tracker.md
- docs/loop/constraints.md

Then execute the next unchecked loop exactly as documented there. Keep the commit
scoped if commits are allowed, run verification, update tracker and handoff, and
create the next verified continuation if unchecked work remains.
```

Important boundary: terminal setup can install the files. Creating the next Codex Desktop session is done by Codex while an active session is running, using the Codex thread tools. It is not a background daemon.

### Continuation Session Health Check

`create_thread` can return before the new Codex thread is fully usable. Treat the returned ID as provisional until it is verified.

After creating a continuation session:

1. Run `list_threads` or `read_thread` for the returned ID.
2. Rename the thread to the planned phase title with `set_thread_title`.
3. Run `read_thread` again and confirm:
   - the thread is visible;
   - the title is correct;
   - the first turn exists;
   - the status is `inProgress` or completed normally;
   - recent items show the agent started reading the handoff or skill docs.
4. Confirm explicit user-required session settings were applied. Example:
   `model: "gpt-5.5"` and `thinking: "xhigh"` for GPT-5.5 extra high. If a
   requested setting is not exposed by the thread tool, record the limitation in
   the handoff instead of silently dropping it.
5. Only after that, write the thread ID into `tracker.md`, `handoff.md`, and the final response.

If the returned ID cannot be read, cannot be found in `list_threads`, or title updates fail repeatedly:

- do not report it as the next session;
- do not write the ID into the project docs;
- mark it as stale if it was already written;
- create one replacement continuation session;
- verify the replacement before recording it.

If a visible continuation thread stays `inProgress` without any new items for an unusual amount of time, treat it as possibly wedged. Read the thread status first. If it is unreadable or unopenable, create a replacement from the current repo handoff and update the stale ID out of the docs.

## Stop Conditions

Codex should stop instead of continuing when:

- the goal is verified
- the tracker is complete
- required verification cannot run
- a blocker needs human input
- credentials or private external data are required
- a destructive command or production action is needed
- the budget is reached
- the next step would violate constraints

Stopping with a clear blocker is a successful loop outcome. It prevents fake progress.

## Maintenance

After each real project checkpoint, keep these files current:

- `goal.md`: update only when the objective changes.
- `tracker.md`: update phase status, evidence, and next action.
- `constraints.md`: update when a new boundary is discovered.
- `handoff.md`: update every checkpoint.

Commit the loop files with the code or artifact changes they describe.

## Troubleshooting

If Codex keeps asking what to do next:

- Make `tracker.md` more explicit.
- Add a single `Current Next Action`.
- Name the exact files to read first.

If Codex claims success too early:

- Strengthen `Done When`.
- Add specific verification commands.
- Require evidence in the tracker before marking a phase complete.

If the loop drifts:

- Tighten `constraints.md`.
- Add non-goals to `goal.md`.
- Reduce the checkpoint size.

If the loop cannot continue:

- Mark the phase `[!] blocked`.
- Put the exact missing input in `handoff.md`.
- Stop until the human provides the missing approval, data, or credentials.

## Uninstall

Remove the loop files from the target project:

```bash
rm -rf docs/loop
```

If you installed them in another folder, remove that folder instead.

## Further Reading

- [Loop Engineering - Addy Osmani](https://addyosmani.com/blog/loop-engineering/)
- [Follow a goal - OpenAI Codex docs](https://developers.openai.com/codex/use-cases/follow-goals)
- [Using Goals in Codex - OpenAI Cookbook](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)
- [Codex best practices - OpenAI Developers](https://developers.openai.com/codex/learn/best-practices)
