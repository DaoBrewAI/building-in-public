---
name: codex-loop-engineering
description: Repo-first Codex loop execution and continuation management. Use when the user asks Codex to continue a loop, run the next checkpoint, install or repair docs/loop goal/tracker/constraints/handoff files, auto-chain the next Codex session, diagnose stuck/dead continuation threads, or make long-running Codex work smoother with verified handoff and thread health checks.
---

# Codex Loop Engineering

Use this skill to run a repo-local Codex loop from durable files instead of a giant chat prompt.

## Core Model

Treat the current project files as authoritative:

```text
docs/loop/goal.md
docs/loop/tracker.md
docs/loop/constraints.md
docs/loop/handoff.md
```

Memory can remind you of Neo's preferences, and this skill can automate the ritual, but the repo loop files are the execution contract.

## First Move

Announce briefly that you are using this skill.

Then discover the loop:

1. Prefer the loop directory named by the user.
2. Otherwise check `docs/loop/`.
3. If no loop exists and the user asked to set one up, run this skill package's `install.sh` from the target repo.
4. If no loop exists and the user asked to continue, stop and ask for the intended loop docs or install permission.

For quick inspection, run:

```bash
python <skill-dir>/scripts/loop_doctor.py --loop-dir docs/loop --json
```

Use the output as orientation only. Still read the actual loop files before editing.

## Read Order

Read these before doing task work:

1. `goal.md`
2. `tracker.md`
3. `constraints.md`
4. `handoff.md`
5. Any project-specific source-of-truth files named by those docs

If the user prompt conflicts with loop files, inspect current artifacts before deciding. Prefer the freshest verified repo state over memory or stale prompt text. Note any correction in the handoff.

## Checkpoint Execution

Run exactly one coherent checkpoint unless the loop files explicitly say otherwise.
This means one implementation/checkpoint slice in the current session. It does
not mean the project should stop after the checkpoint when unchecked work
remains.

Default sequence:

1. Confirm the current checkpoint and stop conditions.
2. Implement only the next unchecked tracker item.
3. Run the verification named in the tracker or handoff.
4. Update tracker and handoff with evidence paths, commands, and remaining work.
5. Inspect local changes.
6. Commit/push only if the project constraints or user request require it.
7. If unchecked work remains and no stop condition applies, create the next
   verified continuation session. Do not leave the user to start it manually.

Stop on blockers that need credentials, external data, destructive action, production deploys, or user approval.

## Auto-Chain Protocol

For a loop continuation, delegated loop run, or any session where the user has
asked Codex to continue a multi-phase repo loop, auto-chain is the default close
out when unchecked work remains. Do not interpret "one checkpoint only" as "do
not create the next session."

Create the next session unless one of these is true:

- the tracker has no unchecked work left;
- the user explicitly says not to create the next session, stop here, or only
  update the handoff;
- `constraints.md` or `handoff.md` explicitly disables auto-chain for this loop;
- the checkpoint is blocked on credentials, external data, destructive action,
  production deploy, or user approval;
- required thread-management tools are unavailable after discovery.

If a loop file has `auto_chain_next_session: false`, treat it as a disable only
when it is fresh and explicit for the current loop. If the user prompt says to
continue or create the next session, the user prompt wins and the handoff should
be corrected.

If thread-management tools are not already available, discover them before
stopping. In Codex Desktop, search for the thread tools first: `create_thread`,
`set_thread_title`, `list_threads`, and `read_thread`. If discovery or a backend
handler fails, record the tool/backend failure in the handoff and final answer
instead of silently ending without a next session.

Before creating the next session:

1. Update tracker and handoff first.
2. Ensure the next checkpoint is specific and scoped.
3. Build a short continuation prompt that points at the loop files and names the
   exact next unchecked tracker item.
4. Preserve any explicit user-required session settings from the current loop
   contract, such as model, reasoning effort, service tier, or mode. If the
   user requires a specific Codex model/thinking setting, pass it explicitly to
   `create_thread`; do not rely on defaults.
5. Use a fresh project-local Codex thread, not a fork, unless the user explicitly asks for a fork.

## Required Tracking

The repo files are the durable source of truth. Track both the completed
checkpoint and the next session.

Before `create_thread`, write:

- in `tracker.md`: the completed checkbox, the next unchecked item, and any
  verification evidence the tracker is expected to carry;
- in `handoff.md`: files changed, commands run, verification result, blockers,
  current branch/path, next unchecked item, and the exact continuation prompt.

After the new session passes the health check, write in both `tracker.md` and
`handoff.md` when useful:

- verified continuation thread ID and title;
- creation date/time if known;
- requested settings, especially `model`, `thinking`, service tier, and fast
  mode;
- health-check evidence: created, titled, found by list/read, first turn exists,
  status/progress, and whether the next agent started reading loop files;
- any settings that the tool could not expose or verify.

Never write a returned thread ID as the real next session until health check
passes. Until then it is provisional.

After `create_thread`, treat the returned ID as provisional. Do not record or report it as successful until it passes the health check.

## Continuation Health Check

A continuation thread is accepted only after all of these pass:

1. `create_thread` returns a thread ID.
2. `list_threads` or `read_thread` can find that exact ID or exact title.
3. `set_thread_title` succeeds, or `read_thread` confirms the title is already correct.
4. `read_thread` shows the first turn exists.
5. The first turn status is `inProgress` or completed normally.
6. Recent items show the agent started reading the handoff, skill docs, or project files.
7. Any explicit user-required session settings were applied and recorded, such
   as `model=gpt-5.5` and `thinking=xhigh` for extra high thinking. If the tool
   does not expose a requested setting, write that limitation in the handoff and
   do not claim the setting was verified.

Only then write the ID into `tracker.md`, `handoff.md`, and the final response.

If the ID cannot be found, title updates fail repeatedly, or the thread becomes unreadable/unopenable:

- do not report it as the next session;
- remove or mark stale any already-written ID;
- create at most one replacement from the current handoff;
- verify the replacement before recording it.

If a visible continuation appears stuck, inspect it with `read_thread` first. If there are recent progress items, let it continue. If there are no new items for an unusual amount of time and it cannot be opened or read, replace it from the current handoff.

## Install Loop Files

When the user asks to install loop engineering into a project, run from the target repo:

```bash
PROJECT_NAME="<name>" LOOP_DIR="docs/loop" AUTO_CHAIN=true \
  bash <skill-dir>/install.sh
```

Use `AUTO_CHAIN=false` only when the user explicitly wants a one-shot loop that
must not create follow-on sessions.

## Install This Skill

For Codex users, install this whole folder as:

```bash
cp -R codex-loop-engineering ~/.codex/skills/codex-loop-engineering
```

For local development, a symlink is better:

```bash
ln -sfn /path/to/building-in-public/codex-loop-engineering ~/.codex/skills/codex-loop-engineering
```

Restart or reload Codex after installing.
