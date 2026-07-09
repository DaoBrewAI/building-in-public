# Orchestrator

Mission-control orchestration for Claude Code. You talk to **one main session**; it brainstorms your ask into a design, decomposes it into tasks, spawns **real headless `claude -p` worker sessions** in guarded git worktrees, mediates their questions (escalating only decisions that change scope, user-visible behavior, cost, or data), integrates and reviews their work, and is the **only writer of persistent memory**.

Built to fix two problems with juggling many Claude Code sessions:
1. Losing context when hopping between windows.
2. Parallel sessions corrupting each other's memory.

## Install

Local (this machine — a `local-dev` marketplace manifest already exists at `~/.claude/plugins/local/`):

```
/plugin marketplace add ~/.claude/plugins/local
/plugin install orchestrator@local-dev
```

Or per-session: `claude --plugin-dir ~/.claude/plugins/local/orchestrator`

Teammates, via marketplace (once the plugin is added to the repo):

```
/plugin marketplace add DaoBrewAI/building-in-public
/plugin install orchestrator
```

The command is namespaced `/orchestrator:orchestrate`; a user-level alias at `~/.claude/commands/orchestrate.md` provides bare `/orchestrate` (copy that one file to get the short form on other machines).

Requires: `git`, `jq`, `uuidgen` (all standard on macOS), and the `10x-engineer` plugin (workers follow its pipeline: writing-plans → TDD → verification).

## Use

From your umbrella folder (the directory that contains your project repos):

```
/orchestrate add retry logic to the cuff sync and bump the endpoint schema
```

That's it. The orchestrator will:
1. **Brainstorm** the ask with you (last unstructured conversation you'll have).
2. **Decompose** into tasks — you confirm the board once.
3. **Spawn** workers (Opus 4.8, extra-high effort) in isolated worktrees, max 2 concurrent, max 1 per repo.
4. **Mediate** — workers never talk to you; blocked questions come to the orchestrator, which answers from the design/decision ledger or escalates the few that matter.
5. **Integrate** — review + tests per branch, merge in dependency order.
6. **Report** — one consolidated summary; durable learnings written to memory exactly once.

Bare `/orchestrate` in any fresh session resumes an in-flight mission. When the main session's context passes 65%, it hands you a one-line instruction to open a fresh session — workers are unaffected.

## The hub

All state lives in `.orchestrator/` at your umbrella folder (found by nearest-ancestor search, created on first run):

```
.orchestrator/
├── MISSION.md          # ask · phase · design link · worker cap
├── TASKS.md            # board: ID | Title | Repo | Branch | Scope | State | Depends on | Notes
├── board.html          # regenerated HTML view of the board (open in a browser)
├── DECISIONS.md        # append-only ledger of every mediation ruling
├── MEMORY.md           # single-writer memory with TTL tags (durable | mission | task-T<ID>)
├── CARRYOVER.md        # exists only mid-handoff
├── designs/            # brainstorming outputs
├── tasks/T01-<slug>/   # brief.md · state · session.txt · plan.md · BLOCKED/ANSWER · report.md
└── archive/            # finished missions, moved whole
```

`cat tasks/*/state` is the entire polling mechanism. Everything is markdown; no daemons.

## Worker guards (4 layers)

1. Orchestrator creates the worktree + branch (`orc/<mission>/T<ID>-<slug>`); workers never choose repo or branch; cwd locked to the worktree.
2. Step-0 self-check in every brief: `pwd` + `git rev-parse` must match the brief, else immediate BLOCKED.
3. A PreToolUse hook written into each worktree blocks `git checkout/switch/merge/rebase/push` and any Write/Edit outside the worktree + the worker's own hub task folder (workers run `--dangerously-skip-permissions`; hooks fire regardless).
4. At integration: branch must match the board, diff must stay inside the declared Scope, hub untouched outside the task dir.

## Memory discipline

- Workers receive a curated context digest in their brief and write only inside their own task folder. They never touch CLAUDE.md, auto-memory, or hub memory.
- The orchestrator writes `MEMORY.md` once per mission, at the end. Entries carry a TTL tag:
  - `ttl:task-T<ID>` — pruned when that task merges
  - `ttl:mission` — pruned when the mission archives
  - `ttl:durable` — kept, and mirrored into the orchestrator's global auto-memory
