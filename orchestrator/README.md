# Orchestrator 0.5.4

Native Codex mission control with explicit backend ownership:

- Each new mission first chooses Fable / Opus or GPT-5.6-Sol Ultra for
  brainstorm, design, plan, review, and re-review.
- Visible Codex GPT-5.6-Sol child tasks implement and rework one approved DAG
  node each.
- The coordinator owns durable authority, scheduling, integration, mediation,
  cleanup, and continuation.
- Every user-facing HTML handoff uses an owner-only OpenAI Sites HTTPS URL for
  phone and desktop access.

The package supports only native mission-schema authority `0.4.0` (a protocol
ID, not the plugin release number). Historical 0.2 and 0.3
coordinator/executor paths are intentionally removed.

## Install

```text
codex plugin marketplace upgrade building-in-public
codex plugin add orchestrator@building-in-public
```

Start a new Codex task after installation so the new skill and hooks load.

Claude Code uses the same native skill tree:

```text
/plugin marketplace add DaoBrewAI/building-in-public
/plugin install 10x-engineer
/plugin install orchestrator
```

Invoke `/orchestrator:orchestrate <ask>`. The Claude package is a thin host
adapter; it does not carry a second coordinator implementation.

## Workflow

1. **Reconcile** — report-only hub discovery; unrelated cleanup never blocks a
   new mission.
2. **Record and provision** — persist the request and native authority, create
   guarded mission worktrees, and attest the baseline.
3. **Selected-backend brainstorm and plan** — use Fable/Opus or one visible
   same-project GPT-5.6-Sol Ultra planning task to ask material clarification
   questions, write design/plan/review companion/task DAG, publish the review
   companion at the stable private Sites `/plan` URL, then pause once at founder
   **go**.
4. **Visible Codex DAG execution** — use the app-native task API to create every
   child and native worktree under the coordinator's saved Git project, adopt
   that exact worktree into guarded Orchestrator authority, use native follow-up
   messaging, consume only compact lifecycle output, broker commits, and
   integrate each verified tip while retaining its resources.
5. **Selected-backend review and retained rework** — after every task is
   integrated, keep all child worktrees/windows and reuse the accepted
   planning/review session plus the exact implementation thread for every
   finding.
6. **Acceptance and batch cleanup** — verify the merged tree, generate verified
   status truth, publish the private Sites `/status` URL, mark accepted, archive
   every child window, then run one mission-scoped GC pass.

The coordinator needs OpenAI Sites building and hosting capability at human
HTML gates. If that capability is unavailable, it preserves the canonical HTML
and stops before asking the user to approve a local-only file.

## Progressive disclosure

The entry skill is intentionally short. It loads detailed protocols only at the
stage that needs them:

| Reference | Loaded for |
|---|---|
| `references/task-execution.md` | ready set, child creation/health, outcomes, integration |
| `references/planning-and-review.md` | backend selection, planning session, review/re-review |
| `references/html-sites-delivery.md` | Sites-first plan, status-truth, and surfaced board HTML |
| `references/cleanup-and-rework.md` | GC, task-window archive, rework, parent collection |
| `references/continuation.md` | compaction, continuation acceptance, promotion |

This keeps ordinary startup and planning context focused while retaining exact
safety contracts for destructive or concurrency-sensitive stages.

## Native authority

Each mission has:

```text
.orchestrator/
├── missions/<mission>/
│   ├── request.md
│   ├── MISSION.md
│   ├── state
│   ├── design.md
│   ├── plan.md
│   ├── plan-review.html
│   ├── status-truth.html
│   ├── task-dag.json
│   └── report.md
├── control/<mission>/
│   ├── pipeline-version          # exactly 0.4.0
│   ├── worktrees.txt
│   ├── approved-design.md
│   ├── approved-plan.md
│   ├── brief-exec.md
│   ├── approved-task-dag.json
│   ├── approved.sha256
│   ├── sites-delivery.json
│   └── tasks/<task-id>/
├── archive/
├── DECISIONS.md
├── MEMORY.md
└── board.html
```

Mission-local copies are worker context; coordinator control is authority.
`verify-approved-authority.py` checks the exact four-file hash manifest before
broker, integration, continuation, or GC may trust the DAG.

## Execution safety

- Work happens only in isolated `orc/<mission>` and
  `orc-task/<mission>/<task>` worktrees.
- App-native task creation produces one independent context and worktree;
  `task-worktree.sh adopt` validates and registers that same worktree inside a
  shared lifecycle lock.
- Every coordinator mutation also serializes on the mission's single
  `.coordinator-lifecycle.lock`; helper-specific locks are nested inside it.
- Native child health reuses the Loop Engineering identity/title/list/read/
  first-turn sequence. Adoption atomically binds the native thread ID, window
  state, worktree, branch, generation, sandbox, and one coordinator-owned
  outcome nonce; the child never needs an external writable root.
- Children edit only their project worktrees and return strict terminal
  outcomes. The coordinator validates and persists external task state, reruns
  frozen verification, and authors every identity-bound broker request.
- Every child creation request targets the coordinator's exact saved project.
  Native list/read must return the same non-null `projectId`; a missing or
  different saved-project ID is rejected.
- App Server is lifecycle inspection only; it never creates, resumes, or
  executes a Desktop-owned task.
- Child MCP/tool/token/item events remain in the child thread and are not
  replayed into the coordinator context.
- The commit broker validates exact paths and never accepts planted settings.
- Integration uses immutable verified child-tip SHAs and normal merge commits;
  no rebase/squash/reset/amend history rewriting.
- Dirty, drifted, unmerged, malformed, or nonterminal resources fail closed.

## Garbage collection

Phase 0 is always report-only:

```text
scripts/orchestrator-gc.sh --hub <hub>
```

Destructive collection is always one exact mission:

```text
scripts/orchestrator-gc.sh --hub <hub> --mission <mission> --clean
```

GC verifies recorded identity, clean worktrees, target ancestry, current
generation, manifest hashes, and exact local/remote tips. It publishes fsynced
intent and journal records before deletion. Failure becomes retriable
`cleanup_pending`; unrelated warnings never block new scheduling. Target/default
branches are never deletion targets.

Integrated child resources remain visible through selected-backend review and
every rework round. Only after clean final review and acceptance does one batch
archive all child windows and collect their exact residual Git resources.
Per-task eager GC and GC-before-review are forbidden.

## Continuation

Codex `PreCompact` and compact `SessionStart` hooks persist an immutable,
request-scoped coordinator carryover. A new project-local task is provisional
until list/read/title/startup/settings health checks pass. At most one replacement
is allowed. Promotion has one atomic authority commit marker, so old and new
coordinators can never both own the same request.

## Package map

| Path | Purpose |
|---|---|
| `.codex-plugin/plugin.json` | Codex manifest and UI metadata |
| `skills/` | compact coordinator and mediation entry skills |
| `skills/orchestrating/references/` | stage-specific detailed contracts |
| `scripts/` | launch, guards, DAG/task lifecycle, broker, integration, GC |
| `hooks/` | durable Codex continuation |
| `templates/` | mission, plan/execution/task briefs, DAG, report, board |
| `tests/` | native lifecycle, race, authority, safety, and E2E contracts |

## Verification

Run the complete native suite:

```text
bash orchestrator/tests/run.sh
```

Every test uses temporary repositories, worktrees, remotes, and hubs. The suite
does not mutate real mission resources.
