# Orchestrator

Mission-control orchestration for Codex and Claude Code. One coordinator turns
an ask into a validated design, provisions isolated git worktrees, launches one
autonomous agent session per mission, mediates material blockers, verifies the
result, and integrates it. Durable state lives in a repo-local `.orchestrator/`
hub so a fresh task can reconstruct every mission.

## Codex installation

Install both the execution workflow and the orchestrator:

```bash
codex plugin marketplace add DaoBrewAI/building-in-public --ref main
codex plugin add 10x-engineer@building-in-public
codex plugin add orchestrator@building-in-public
```

Start a new Codex task, open the umbrella folder that contains your repos, and
ask:

```text
Use $orchestrating to add retry logic to the cuff sync and update the endpoint schema.
```

The Codex edition uses `codex exec --json` workers. Each worker runs with:

- the primary worktree as its current directory;
- `workspace-write` sandboxing;
- only the mission directory and other declared worktrees added as writable;
- inherited additional writable roots cleared and implicit `/tmp`/`$TMPDIR`
  write access excluded;
- non-interactive approvals disabled so blocked actions fail instead of hanging;
- a persistent Codex `thread_id` captured from JSONL for resume.

Codex intentionally protects linked-worktree Git metadata inside
`workspace-write`. Workers therefore leave reviewed changes uncommitted. After
the turn, the launcher validates the plan/report/manifest. Once the worker is
dead, the coordinator inspects the diff and runs one vetted commit-broker
command with host approval. It reads a coordinator-owned control manifest kept
outside all worker-writable roots, requires the worker-facing copy to match,
rejects policy-memory changes, and creates one mission commit per worktree. The
worker never bypasses hook trust or the sandbox.

The default worker is `gpt-5.6` at `xhigh` reasoning. Set
`ORC_CODEX_MODEL` or `ORC_CODEX_EFFORT` to override it.

Codex does not guarantee a generic process-exit callback into a dormant task.
The launcher therefore writes state immediately, keeps a terminal process
handle when the host exposes one, sends a macOS notification on exit, and makes
every later invocation reconcile the hub before doing anything else.

## Claude Code installation

The Claude Code package (v0.3.0) lives in `.claude-plugin/`, `claude-skills/`,
`commands/`, `hooks/`, `scripts/`, and `templates/`. Since 0.3.0 each mission runs
a **staged model pipeline**: a headless `claude -p` session (Fable-5, effort high)
plans and pauses in `planned` until you say go, execution + verification run on
headless Codex (`gpt-5.6-sol`, reasoning high, workspace-write sandbox), then the
same Fable-5 session is resumed to code-review. It therefore also requires the
Codex CLI (`codex` on PATH or the ChatGPT.app bundled binary; `ORC_CODEX_BIN`
overrides).

```text
/plugin marketplace add DaoBrewAI/building-in-public
/plugin install 10x-engineer
/plugin install orchestrator
```

Use `/orchestrator:orchestrate <ask>` or your local `/orchestrate` alias.

## Mission lifecycle

1. **Brainstorm** — validate scope, acceptance criteria, non-goals, and affected repos.
2. **Provision** — create one `orc/<mission-slug>` worktree per repo and record an immutable manifest and brief.
3. **Launch** — one persistent worker owns planning, TDD implementation, self-review, verification, commit checkpoints, and report; the launcher validates afterward.
4. **Mediate** — workers write `BLOCKED-n.md`; the coordinator decides reversible details and escalates only scope, user-visible behavior, cost, or data.
5. **Accept** — verify artifacts and diff scope, merge without committing, run the full suite, then commit on pass or abort and resume on failure.
6. **Clean up** — remove generated policy, worktrees, and merged mission branches; archive durable mission state.

Only one active mission may own a repo. Conflicting missions remain `pending`
until the active mission is accepted or failed.

## Hub layout

```text
.orchestrator/
├── missions/<date>-<slug>/
│   ├── MISSION.md
│   ├── design.md
│   ├── brief.md
│   ├── state
│   ├── worktrees.txt
│   ├── session.txt
│   ├── commits.txt
│   ├── plan.md
│   ├── BLOCKED-n.md / ANSWER-n.md
│   ├── report.md
│   └── worker-output-* + worker-stderr.log
├── control/<date>-<slug>.worktrees  # coordinator-owned; never worker-writable
├── DECISIONS.md
├── MEMORY.md
├── board.html
└── archive/
```

`state` is always one of `pending`, `running`, `blocked`, `review`, `accepted`,
or `failed`. A dead process never implies lost work: the coordinator inspects
the recorded thread, branches, artifacts, and JSONL before resuming or respawning.

## Guards

The Codex edition uses three layers:

1. OS sandbox roots restrict writes to mission workspaces and the mission directory.
2. A post-turn gate requires a plan, filled review/verification evidence, and an unchanged copy of coordinator-owned worktree authority; after inspection, a separately approved broker rejects policy-memory changes and creates commits outside the worker sandbox.
3. Coordinator acceptance verifies commit and diff scope and reruns each repository's tests on the pending merge.

The OS sandbox, trusted wrapper, and acceptance checks are the enforcement
boundaries. The launcher never bypasses the Codex sandbox or hook trust.

## Dual-host layout

| Path | Host |
|---|---|
| `.codex-plugin/`, `skills/`, `codex-scripts/`, `codex-templates/`, `codex-tests/` | Codex |
| `.claude-plugin/`, `claude-skills/`, `commands/`, `hooks/`, `scripts/`, `templates/`, `tests/` | Claude Code |

Both editions implement the same v0.2 mission protocol and can inspect the
same disk state, but a mission must be resumed by the host that created its
recorded session.
