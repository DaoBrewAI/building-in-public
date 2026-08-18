# Orchestrator

Mission-control orchestration for Codex and Claude Code. One coordinator turns
an ask into a validated design, provisions isolated git worktrees, launches one
autonomous agent session per mission, mediates material blockers, verifies the
result, and integrates it. Durable state lives in a repo-local `.orchestrator/`
hub so a fresh task can reconstruct every mission.

## Codex Hybrid 0.3 installation

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

The Codex 0.3 edition uses the same Hybrid staged pipeline as the Claude 0.3
edition, with fixed backend ownership:

1. The Codex app task coordinates state, worktrees, mediation, acceptance, and
   merge.
2. A headless `claude-fable-5 --effort high` session brainstorms the request,
   writes the design and plan, and pauses at the founder `go` gate.
3. A separate `codex exec -m gpt-5.6-sol` thread implements the whole plan and
   verifies it in a `workspace-write` sandbox.
4. The original Fable session resumes for independent code review. Findings
   return to the original Codex thread as `rework`; Fable re-reviews afterward.

Fable is read-only on every worktree. All implementation, test fixes, and
review-driven patches belong to GPT-5.6-Sol. Fable receives no Bash tool; the
coordinator supplies immutable diff snapshots for review. The Codex sandbox keeps linked
worktree Git metadata read-only, so the executor writes
`COMMIT-REQUEST-<n>.json`; `scripts/commit-broker.sh` validates each request and
creates the commit outside the sandbox without handing Codex broader access.
The broker trusts only `$HUB/control/<mission-slug>/worktrees.txt`, never the
worker-writable copy.

Mission hooks coexist with repository-owned Claude configuration. Shared,
Git-tracked project settings remain in `.claude/settings.json`; Orchestrator
installs guard and gate hooks in Claude's higher-precedence local project layer,
`.claude/settings.local.json`, and excludes that temporary file through the
worktree's Git metadata. Its SHA-256 is frozen in coordinator-owned control
state and verified before every Fable plan/review turn. Provisioning uses an
atomic no-clobber install and fails closed if local settings already exist, so
Orchestrator never overwrites a developer's private configuration.

The Hybrid launcher and state machine live in `scripts/` and `templates/` and
are shared by both coordinator surfaces. New Codex missions use these shared
assets. Model ownership is a plugin invariant and is not configurable per
mission.

Requires `git`, `jq`, `uuidgen`, the Claude CLI authenticated for Fable-5, the
Codex CLI authenticated for GPT-5.6-Sol, and the `10x-engineer` plugin on the
Claude side. Start a new Codex task after installation so the 0.3 skill text is
loaded.

### Legacy Codex 0.2 compatibility

The `codex-scripts/`, `codex-templates/`, and `codex-tests/` trees remain for
missions already created by the 0.2 single-Codex pipeline. The 0.3 coordinator
detects those missions by their legacy mission/template shape as well as their
session shape, including pending missions with no session yet, and resumes them
with the legacy launcher. It never silently switches an in-flight mission
between state machines. New missions always use the Hybrid 0.3 shared assets.

## Claude Code installation

The Claude Code edition lives in `.claude-plugin/`, `claude-skills/`,
`commands/`, `hooks/`, `scripts/`, `templates/`, and `tests/`.

```text
/plugin marketplace add DaoBrewAI/building-in-public
/plugin install 10x-engineer
/plugin install orchestrator
```

Use `/orchestrator:orchestrate <ask>` or your local `/orchestrate` alias.
Requires `git`, `jq`, `uuidgen`, the Codex CLI (`codex` on PATH or the
ChatGPT.app bundled binary; `ORC_CODEX_BIN` overrides), and the `10x-engineer`
plugin.

Since v0.3 each new mission runs as a **staged pipeline**: a headless `claude -p`
session plans and pauses at a founder go-gate (`planned`), a `codex exec`
worker executes and verifies inside a `workspace-write` sandbox, then the same
claude session is resumed to code-review. Hardening from the first live
mission retrospective (22 BLOCKEDs, 19 eliminable):

- **Commit broker** (`scripts/commit-broker.sh`) — the Codex sandbox keeps git
  metadata read-only, so the executor writes `COMMIT-REQUEST-<n>.json` and
  polls in-turn for `COMMIT-DONE-<n>.json` instead of a BLOCKED round-trip per
  task; the broker validates the path manifest before committing.
- **Provision preflight** (`scripts/provision-preflight.sh`) — installs
  dependencies, pre-creates in-worktree Swift caches, and runs the full
  baseline **outside the sandbox** into `baseline-attestation.json`; briefs
  carry a sandbox-facts section and an accepted-failure-set rule so sandbox
  noise is never mistaken for a regression.
- **Quota-limit detection** — `spawn-worker.sh` recognizes session/usage-limit
  kills, exits 75 with a `retry_after` hint, and the coordinator schedules a
  delayed respawn instead of counting a crash strike.
- **Tighter pipeline gate** — a turn that ends with mission state still
  `running` is bounced back until the session records
  planned/executed/blocked/review.
- **Planner hardening** — reuse claims require `file:line` citations from real
  code, contract-changing tasks annotate their compile-impact surface, and
  every checkpoint must compile independently.
- **`scripts/orchestrator-gc.sh`** — state-gated cleanup for completed mission
  worktrees plus local and remote `orc/` branches; Phase 6 invokes it with
  `--clean` automatically after a successful merge.

## Mission lifecycle

1. **Record and provision** — preserve the original ask, create one guarded
   `orc/<mission-slug>` worktree per repo, and render both backend briefs.
2. **Fable brainstorm + plan** — the same Fable session creates design.md,
   plan.md, and plan-review.html, then enters `planned`.
3. **Founder go** — review design decisions, approve the implementation plan,
   and freeze design, plan, and executor brief in coordinator-owned control.
4. **Codex execute** — GPT-5.6-Sol implements with TDD, verification, and
   brokered commit checkpoints, then enters `executed`.
5. **Fable review** — resume the original Fable session. Code findings enter
   `rework` and return to the original Codex thread until clean.
6. **Accept and clean up** — verify frozen artifacts, diff scope, Fable verdict,
   and Codex test evidence; commit only a verified merge, remove mission
   policy/worktrees, and archive state.

Missions sharing a repo run in parallel by default — isolation is per-worktree,
not per-repo, since each mission owns its own worktree and `orc/<mission-slug>`
branch. A mission is held `pending` only when it would reuse another mission's
worktree or branch, or when it genuinely depends on another's output (builds on
unmerged commits, collides on the same files at merge, or shares a contract or
migration chain). It then launches automatically once the blocker is accepted or
failed.

## Hub layout

```text
.orchestrator/
├── missions/<date>-<slug>/
│   ├── MISSION.md
│   ├── request.md
│   ├── design.md
│   ├── brief.md
│   ├── brief-exec.md
│   ├── state
│   ├── worktrees.txt
│   ├── session.txt
│   ├── commits.txt
│   ├── plan.md
│   ├── plan-review.html
│   ├── BLOCKED-n.md / ANSWER-n.md
│   ├── report.md
│   └── worker-output-* + worker-stderr.log
├── control/<date>-<slug>/
│   ├── worktrees.txt
│   ├── approved-design.md
│   ├── approved-plan.md
│   ├── brief-exec.md
│   ├── approved.sha256
│   ├── worker-settings.sha256
│   └── review-diff-*.patch
├── DECISIONS.md
├── MEMORY.md
├── board.html
└── archive/
```

`state` is one of `pending`, `running`, `planned`, `executed`, `rework`,
`blocked`, `review`, `accepted`, or `failed`. A dead process never implies lost
work: the coordinator inspects the last recorded stage, both session IDs,
branches, artifacts, and output before resuming or respawning.

## Guards

Hybrid 0.3 uses five layers:

1. Claude receives no Bash tool; hooks restrict Write/Edit to mission artifacts,
   making brainstorm/plan/review read-only on every worktree.
2. Codex OS sandbox roots restrict executor writes to mission workspaces and the
   mission directory.
3. The go gate freezes the approved contract and worktree manifest outside all
   worker-writable roots; the broker and executor use only that authority.
4. The pipeline gate requires design/plan/review/verification artifacts, while
   the commit broker validates executor commit requests outside the sandbox.
5. Coordinator acceptance verifies artifact and diff scope; any verification
   that may write is routed to the same Codex executor.

The OS sandbox, trusted wrapper, and acceptance checks are the enforcement
boundaries. The launcher never bypasses the Codex sandbox or hook trust.

## Dual-host layout

| Path | Host |
|---|---|
| `.codex-plugin/`, `skills/` | Codex coordinator surface |
| `.claude-plugin/`, `claude-skills/`, `commands/`, `hooks/` | Claude coordinator surface |
| `scripts/`, `templates/`, `tests/` | Shared Hybrid 0.3 pipeline |
| `codex-scripts/`, `codex-templates/`, `codex-tests/` | Legacy Codex 0.2 compatibility |

Both 0.3 coordinator surfaces enter the same staged state machine and can
reconstruct its disk state. Each stage must still be resumed by its recorded
backend: brainstorm/plan/review on the Claude session ID, execution/rework on
the Codex thread ID.
