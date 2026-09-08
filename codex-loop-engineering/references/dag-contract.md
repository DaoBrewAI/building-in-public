# DAG execution contract

Four Markdown files are the human contract. For concurrent lanes, add
`execution.json` as the dispatch manifest and keep it aligned with tracker and
current user authority. [The example](../templates/execution.example.json) is a
shape, not an authorized job. Linear loops do not need a manifest.

## One node, one outcome and owner

Declare ID/phase/dependencies; base/worktree/input refs; repo-relative write files
or directory roots; exclusive browser/port/state/account resources; session
model/effort/tier; acceptance/verifier; attempts and approved budgets; lifecycle,
launch reservation/runtime reference and evidence.

`max_parallelism` counts launching/running execution nodes; start with two.
Disjoint files can still share a mutable runtime. Common frozen reads are fine;
modifying another lane's contracts is not. Use exact paths/roots, not globs.

## Readiness

A candidate is planned, unreserved, and has only accepted complete predecessors
with evidence references. Read those artifacts before release. Reserve the launch
before calling the tool, then record the verified ID to prevent duplicates during
slow or ambiguous creation.

The read-only checker validates shape, cycles, dependencies, session settings,
Fast authority, active ownership/resource conflicts and capacity. It selects
nonconflicting candidates in manifest order. It checks declared references, not
their truth, model availability or user authority. `dispatchable` is a scheduling
suggestion, not permission.

```bash
python <skill>/scripts/loop_doctor.py --loop-dir docs/loop/example --json
```

Plan/review mode never dispatches even if a stale authorization boolean is true.
Invalid manifests fail closed. Legacy summaries remain orientation only; a
quoted old auto-chain flag is not a current GO.

## Acyclic dependencies and bounded attempts

Represent acceptance dependencies as a DAG. Diagnose/repair/verify can be bounded
attempts within a node. Repeated failure produces a scoped repair/replan decision,
not an unconditional cycle or a new controller every time.

- Engineering node state: planned, launching, running, blocked, complete or
  cancelled. Here complete means checkpoint acceptance with evidence.
- Product run state: execution may complete while quality/user verification is
  pending or failed. Do not use engineering acceptance to invent product success.

User phase order is an additional release constraint. Technically independent
later work cannot bypass an authorized stage. Read-only design may continue when
allowed; implementation remains gated.

## Version and integration consistency

Fix request scope, source/build/method/preferences, permission bindings and
already-supplied inputs at start. After acquisition, seal the evidence/coverage
snapshot before analysis. Supplemental acquisition creates a new revision and
invalidates affected descendants explicitly.

A user refinement is a new product child Run; a technical retry is an attempt
inside its step. Preserve old artifacts/receipts. Never let an executor and its
integration adapter each run an independent retry clock for the same action.

A worktree is another checkout sharing Git objects; it can use a branch or a
detached commit. Prefer a named local experiment branch for persistent concurrent
development; detached worktrees suit verification/scoped publication. Follow
explicit repository direct-branch rules.

Inspect remote tips/authors before choosing a base. An unchanged integration
branch does not mean a collaborator has no new feature-branch work. Reserve
overlapping modules by owner. Integrate coherent dependency sets after acceptance;
don't cherry-pick half a coupled schema/security migration or rewrite a peer's
branch without authority.

One integrator owns shared interfaces and local acceptance. Commit, push and
deploy are separately scoped. Skill publication does not authorize product-code
publication. Verify installed, source and remote skill content separately,
especially when the installed skill is a symlink to an old checkout.

## Manifest fields

- `schema_version`: `codex-loop-execution.v1`.
- `mode`: plan/review/execute; `execution_authorized` and `fast_authorized`: booleans.
- `fast_authority_ref`: current scoped user instruction, verified by Supervisor.
- `session`: model, reasoning_effort, service_tier (`default` normally; `priority`
  only for explicitly authorized Fast), fast_mode.
- `runtime_ref`: active ID or provisional launch reservation.
- `acceptance: passed` plus nonempty `evidence`: required for complete nodes.
- `high_effort_authority_ref`: explicit user override for ultra/max workers;
  supervisors are distinct. Host support remains a separate startup gate.

Rerun the checker after edits. It never changes files, starts a process, accesses
credentials or fixes policy for you.
