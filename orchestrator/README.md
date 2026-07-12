# Orchestrator

Mission-control orchestration for Claude Code. You talk to **one coordinator session** (the session you talk to — called "the orchestrator" below); it brainstorms each ask into a design, then launches **ONE autonomous headless `claude -p` session per mission** that plans, executes, and self-reviews in guarded git worktrees. The orchestrator stays **free for other work**, mediates blocked questions, does light acceptance + merge, and is the **only writer of persistent memory**. All state lives on disk in a `.orchestrator/` hub so any fresh session can resume.

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

Requires: `git`, `jq`, `uuidgen` (all standard on macOS), and the `10x-engineer` plugin (mission sessions follow its pipeline: writing-plans → TDD → verification; the spawn script auto-passes `--plugin-dir` for the cached 10x-engineer plugin so missions get it even if ambient config lacks it).

## Use

From your umbrella folder (the directory that contains your project repos):

```
/orchestrate add retry logic to the cuff sync and bump the endpoint schema
```

That's it. The orchestrator will:

1. **Brainstorm** the ask with you — the last unstructured conversation about this mission.
2. **Provision** — one worktree per involved repo on branch `orc/<mission-slug>`; the guard + pipeline-gate hooks are written into the `.claude/settings.json` of the primary worktree (the first involved repo's, which is also the session's cwd), then that file is validated (parses, no leftover placeholders, scripts executable) before anything launches.
3. **Launch** — the mission runs as one headless session (Opus 4.8, extra-high effort), brief fed on stdin. It plans, executes, self-reviews, verifies, and commits on its own.
4. **You're free** — chat about anything else, code, or launch other missions. Max 1 running mission per repo; a mission that conflicts on a repo queues as `pending` and launches automatically when the blocker finishes.
5. **Mediate** — the mission never talks to you directly; it exits with a `BLOCKED-n.md`, the orchestrator triages (answering most itself, escalating only scope / user-visible behavior / cost / data), writes `ANSWER-n.md`, logs the ruling in the `DECISIONS.md` ledger, and resumes the session.
6. **Light acceptance** (~2 minutes, no re-review of the code) — artifact checks (plan.md, report.md with a real review verdict and real test output) and fence checks, then per repo: `git merge --no-ff --no-commit`, run that repo's test suite against the merged tree, commit on pass or `merge --abort` on fail (your main branch is never left dirty; failures bounce back to the mission session with the failing output).
7. **Cleanup** — all mission worktrees and `orc/<mission-slug>` branches are removed at acceptance; nothing temporary outlives the mission.
8. **Report + memory** — one consolidated summary (what shipped per repo, decisions made on your behalf, test results, follow-ups); durable learnings written to memory exactly once per mission.

A macOS notification fires whenever a mission session exits (blocked / ready for review / crash) — a backup channel in case you're away; come back to the orchestrator chat, or run bare `/orchestrate` in any fresh session, which resumes all in-flight missions from the hub. When the orchestrator's context passes 65%, it writes a carryover file and hands you a one-line instruction to open a fresh session — missions are unaffected.

**When things go wrong:** a crashed mission session is resumed against its recorded session id (headless transcripts usually survive a crash), salvaging what's already on the branches. Two crash deaths, two failed acceptance cycles, or you saying "kill it" put the mission in a `failed` state: you're told what exists, and the worktrees + branches are **kept for salvage** until you decide; a `failed` mission doesn't block new missions on the same repos.

## The hub

All state lives in `.orchestrator/` at your umbrella folder (found by nearest-ancestor search, created on first run):

```
.orchestrator/
├── missions/<date>-<slug>/
│   ├── MISSION.md        # ask · phase · repos · worktrees · session id
│   ├── design.md         # brainstorm output
│   ├── brief.md          # immutable launch instructions
│   ├── state             # pending|running|blocked|review|accepted|failed
│   ├── worktrees.txt     # tab-separated manifest: worktree · branch · base sha · repo
│   ├── plan.md           # written by the mission session
│   ├── BLOCKED-n.md / ANSWER-n.md
│   ├── report.md         # incl. self-review verdict + test output
│   └── worker-output-*.json · session.txt · worker-stderr.log
├── DECISIONS.md          # global ledger; entries prefixed with mission slug
├── MEMORY.md             # single-writer memory with TTL tags (durable | mission)
├── board.html            # one row per mission (open in a browser)
└── archive/              # accepted missions, moved whole
```

`cat missions/*/state` is the entire polling surface. Everything is markdown; no daemons.

## Guards (4 layers)

1. The orchestrator provisions every worktree and branch (`orc/<mission-slug>`); mission sessions never choose a repo or branch, and the session's cwd is locked to the primary worktree.
2. Step-0 self-check in every brief: `pwd` + `git rev-parse` must match the brief, and the required 10x-engineer skills must be available — any mismatch is an immediate BLOCKED.
3. Hooks planted in the primary worktree's `.claude/settings.json`, both of which fire even under `--dangerously-skip-permissions`:
   - a **PreToolUse guard** — a multi-root fence (fail-closed if misconfigured) that blocks `git checkout/switch/merge/rebase/push/worktree` and any Write/Edit outside the mission's worktrees + its own mission directory;
   - a **Stop-hook pipeline gate** — the session can't end its turn in `review` unless plan.md exists, report.md has its Code review and Verification sections with no unfilled `{{...}}` placeholders, and every mission branch has at least one commit; after 3 blocks it releases (acceptance is the backstop).
4. Acceptance fence checks: the diff per repo must stay inside the design's declared scope, branch names must match the manifest, and a committed `.claude/settings.json` (the planted hooks) bounces the mission before merge.

## Memory discipline

- Mission sessions receive a curated context digest in their brief and write only inside their own mission directory. They never touch CLAUDE.md, auto-memory, or hub memory.
- The orchestrator writes `MEMORY.md` once per mission, at acceptance. Entries carry a TTL tag:
  - `ttl:mission` — pruned when the mission archives
  - `ttl:durable` — kept, and mirrored into the orchestrator's global auto-memory

## v0.1 → v0.2

v0.1 split each ask into per-task worker sessions coordinated through a root `MISSION.md` and a `TASKS.md` board. v0.2 replaces that with `missions/` — one autonomous session owns each mission's whole pipeline, and `TASKS.md` is gone. If a v0.1 root `MISSION.md` hub is still in flight, the orchestrator surfaces the choice on your next `/orchestrate`: finish it under the old rules (this repo's git history has them) or archive it manually (move the root `MISSION.md`/`TASKS.md` and `tasks/` into `archive/`); the two layouts are never mixed.
