# Orchestrator DAG/GC Implementation Handoff

## Current state

- Repository: `/Users/linhanyang/Documents/Daobrew/building-in-public`
- Current checkout: `main`
- Existing unrelated changes to preserve: `claude-bridge/config.py`, `.DS_Store`, `figma-swift-tokens.skill`
- Architecture is approved by the user.
- Task 1 completed on 2026-08-21 at `2026-08-21T22:02:12Z`.
- Tasks 2, 3, and 4 are implemented, independently reviewed, and integrated in
  the main checkout. Their focused contracts are green.
- The remaining intentional RED lane is Task 5/6 integration and GC.
- Next dependency-ready checkpoints: Tasks 5 and 7. They are file-disjoint only
  if Task 5 owns integration/GC files and Task 7 owns continuation hook files.
- Auto-chain is authorized for dependency-ready, file-disjoint lanes.
- Child task threads may not create grandchildren; only the coordinator may create tasks.
- User-added cleanup requirement (2026-08-21): completed child Codex task
  windows must be archived after verified integration/resource cleanup. The
  exact accepted thread ID is authoritative; failures are retriable, active or
  unresolved tasks are preserved, and rework unarchives/reuses the same task
  before re-archiving it after reintegration.

## New task prompt

```text
Implement the Orchestrator mission-internal task DAG, child Codex task execution, two-level garbage collection, and durable continuation bridge. Work in this building-in-public repository. First read orchestrator/IMPLEMENTATION-HANDOFF.md and orchestrator/IMPLEMENTATION-PLAN.md completely, then read the existing orchestrator skill, spawn-worker, GC script, briefs, and tests named there. Use 10x-engineer:executing-plans and codex-loop-engineering. Start with Task 1 only, using TDD. Preserve all unrelated working-tree changes. Update this handoff with exact tests/evidence and the ready set. After Task 1, create only dependency-ready, file-disjoint continuation tasks and health-check each provisional thread before recording it. Do not commit, push, open a PR, merge, publish, or delete real branches unless the user separately authorizes it.
```

## Baseline commands to run

```bash
bash orchestrator/tests/run.sh
bash orchestrator/codex-tests/run.sh
git status --short --branch
```

## Task 1 evidence

Pre-change baseline at commit `949032e`:

```text
$ bash orchestrator/tests/run.sh
PASS test-codex-hybrid-plugin.sh          (55/55)
PASS test-commit-broker.sh                (12/12)
PASS test-install-worker-settings.sh      (20/20)
PASS test-orchestrator-gc.sh
PASS test-pipeline-gate.sh                (16/16)
PASS test-spawn-worker.sh                 (10/10)
PASS test-worker-guard.sh                 (22/22)

$ bash orchestrator/codex-tests/run.sh
PASS test-mission-commit.sh
PASS test-pipeline-gate.sh                (11/11)
PASS test-spawn-worker.sh
```

Task 1 RED evidence after adding contract tests:

```text
$ bash orchestrator/tests/test-task-dag-contract.sh
task-dag-contract: 0/10; rc=1

$ bash orchestrator/tests/test-child-worktree-contract.sh
child-worktree-contract: 0/8; rc=1

$ bash orchestrator/tests/test-child-thread-contract.sh
child-thread-contract: 1/13; rc=1

$ bash orchestrator/tests/test-child-integration-gc-contract.sh
child-integration-gc-contract: 0/11; rc=1

$ bash orchestrator/tests/run.sh
Four new contract files FAIL as expected; all seven pre-existing primary tests PASS; rc=1.

$ bash orchestrator/codex-tests/run.sh
All three compatibility tests PASS; rc=0.
```

The RED failures are expected missing capabilities, not fixture or syntax
errors. Their ownership is deliberately file-disjoint:

- Task 2: `tests/test-task-dag-contract.sh`
- Task 3: `tests/test-child-worktree-contract.sh`
- Task 4: `tests/test-child-thread-contract.sh`
- Task 5/6: `tests/test-child-integration-gc-contract.sh`

## Codex hook capability audit

Installed runtime evidence:

```text
$ codex --version
codex-cli 0.148.0-alpha.21

$ codex features list | rg '^(hooks|plugins|plugin_hooks)'
hooks          stable   true
plugin_hooks   removed  false
plugins        stable   true

$ strings /Applications/ChatGPT.app/Contents/Resources/codex | <exact-symbol filter>
.codex-plugin/plugin.json
PostCompact
PreCompact
RawPluginManifestHooks
hooks/hooks.json
transcript_path
```

The current official OpenAI Hooks documentation confirms that Codex supports
`PreCompact`, `PostCompact`, `Stop`, `SessionStart`, and `SessionEnd`, and that
plugins may bundle lifecycle configuration through the plugin manifest or
`hooks/hooks.json`: <https://learn.chatgpt.com/docs/hooks>.

Decision for Task 7: use the supported Codex compaction lifecycle boundary
(`PreCompact`, with `SessionStart source=compact`/manual coordinator fallback as
needed) for durable carryover. Do not copy Claude hook JSON blindly. Do not
claim an exact Codex 65% threshold: the documented hook payload exposes no
stable context-percentage field, and the documentation explicitly says
`transcript_path` format is not a stable hook interface.

## Tasks 2-4 integrated evidence

Fresh evidence in the main checkout after independent spec and quality review:

```text
$ bash orchestrator/tests/test-task-dag-contract.sh
task-dag-contract: 27/27

$ bash orchestrator/tests/test-child-worktree-contract.sh
child-worktree-contract: 24/24

$ bash orchestrator/tests/test-child-thread-contract.sh
child-thread-contract: 34/34

$ bash orchestrator/tests/run.sh
Task DAG, child worktree, child thread, and all seven legacy primary lanes PASS.
Only test-child-integration-gc-contract.sh remains intentionally RED at 3/15.

$ bash orchestrator/codex-tests/run.sh
All three compatibility tests PASS.

$ git diff --check
exit 0
```

Security/recovery acceptance covered canonical path aliases, casefold/NFC file
collisions, approved-hash inheritance, kernel-released advisory freeze locks,
no-clobber publication, exact worktree ownership, concurrent single-winner
creation, signal-window rollback, and child task-window archive/unarchive rules.

## Dependency-ready set after Tasks 2-4

| Task | Why ready | Exclusive file set |
| --- | --- | --- |
| 5. Child integration and immediate GC | Tasks 2+3+4 accepted | `scripts/integrate-task.sh`, `scripts/orchestrator-gc.sh`, `tests/test-child-integration-gc-contract.sh`, `tests/test-orchestrator-gc.sh` |
| 7. Carryover and verified continuation | Task 4 accepted | Codex hook manifest/adapter, continuation template/test, and continuation-only skill documentation |

Task 6 still waits for Task 5. Task 8 waits for Tasks 5+6+7.

## Dependency-ready set after Task 1

| Task | Why ready | Exclusive file set |
| --- | --- | --- |
| 2. Approved task DAG | Task 1 complete; no dependency on Tasks 3/4 | `templates/task-dag.json`, `scripts/validate-task-dag.sh`, `templates/brief-codex.md`, `tests/test-task-dag-contract.sh` |
| 3. Child worktree lifecycle | Task 1 complete; no dependency on Tasks 2/4 | `scripts/task-worktree.sh`, `tests/test-child-worktree-contract.sh` |
| 4. Child thread scheduler | Task 1 complete; no dependency on Tasks 2/3 | `skills/orchestrating/SKILL.md`, `templates/task-brief.md`, `tests/test-child-thread-contract.sh` |

Tasks 5, 6, 7, and 8 are not ready. Task 5 waits for 2+3+4; Task 6 waits for
5; Task 7 waits for 4; Task 8 waits for 5+6+7. No continuation may edit this
handoff or `implementation-notes.md`; the coordinator owns those shared files.

## Exact continuation prompts

### Task 2

```text
Continue the approved Orchestrator DAG/GC implementation at Task 2 only. Your exclusive detached linked worktree is /Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-2; cd there before reading or writing and do not write in any other checkout. First read orchestrator/IMPLEMENTATION-HANDOFF.md and orchestrator/IMPLEMENTATION-PLAN.md completely, then read orchestrator/tests/test-task-dag-contract.sh, orchestrator/templates/brief-codex.md, and the current approved-contract handling in orchestrator/scripts/spawn-worker.sh. Use 10x-engineer:executing-plans and test-driven-development. Own only orchestrator/templates/task-dag.json, orchestrator/scripts/validate-task-dag.sh, orchestrator/templates/brief-codex.md, and orchestrator/tests/test-task-dag-contract.sh. Start by rerunning the focused test and confirming 0/10 RED, then implement the minimum Bash 3.2-compatible Task 2 contract and drive that test GREEN. Do not edit any other file, especially IMPLEMENTATION-HANDOFF.md, implementation-notes.md, the Task 3/4/5 contract tests, claude-bridge/config.py, .DS_Store, or figma-swift-tokens.skill. Do not create child tasks. Do not commit, push, open a PR, merge, publish, or delete branches. End with the exact files changed and raw focused/full-suite evidence; remaining unrelated RED lanes are expected.
```

### Task 3

```text
Continue the approved Orchestrator DAG/GC implementation at Task 3 only. Your exclusive detached linked worktree is /Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-3; cd there before reading or writing and do not write in any other checkout. First read orchestrator/IMPLEMENTATION-HANDOFF.md and orchestrator/IMPLEMENTATION-PLAN.md completely, then read orchestrator/tests/test-child-worktree-contract.sh, orchestrator/scripts/spawn-worker.sh, orchestrator/scripts/orchestrator-gc.sh, and the current manifest-authority tests. Use 10x-engineer:executing-plans and test-driven-development. Own only orchestrator/scripts/task-worktree.sh and orchestrator/tests/test-child-worktree-contract.sh. Start by rerunning the focused test and confirming 0/8 RED, then implement the minimum Bash 3.2-compatible Task 3 lifecycle and drive that test GREEN. Keep all test repositories/remotes temporary; never touch real mission branches or worktrees. Do not edit any other file, especially IMPLEMENTATION-HANDOFF.md, implementation-notes.md, the Task 2/4/5 contract tests, claude-bridge/config.py, .DS_Store, or figma-swift-tokens.skill. Do not create child tasks. Do not commit, push, open a PR, merge, publish, or delete branches. End with the exact files changed and raw focused/full-suite evidence; remaining unrelated RED lanes are expected.
```

### Task 4

```text
Continue the approved Orchestrator DAG/GC implementation at Task 4 only. Your exclusive detached linked worktree is /Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-4; cd there before reading or writing and do not write in any other checkout. First read orchestrator/IMPLEMENTATION-HANDOFF.md and orchestrator/IMPLEMENTATION-PLAN.md completely, then read orchestrator/tests/test-child-thread-contract.sh, orchestrator/skills/orchestrating/SKILL.md, orchestrator/templates/brief-codex.md, orchestrator/templates/brief-exec.md, and the Codex Loop Engineering continuation-health-check contract named in the handoff. Use 10x-engineer:executing-plans, codex-loop-engineering, and test-driven-development. Own only orchestrator/skills/orchestrating/SKILL.md, orchestrator/templates/task-brief.md, and orchestrator/tests/test-child-thread-contract.sh. Start by rerunning the focused test and confirming 1/13 RED, then implement the minimum Task 4 coordinator-only scheduling and durable child-outcome contract and drive that test GREEN. Do not edit any other file, especially IMPLEMENTATION-HANDOFF.md, implementation-notes.md, the Task 2/3/5 contract tests, claude-bridge/config.py, .DS_Store, or figma-swift-tokens.skill. Do not create child tasks or grandchildren; only this coordinator creates continuation tasks. Do not commit, push, open a PR, merge, publish, or delete branches. End with the exact files changed and raw focused/full-suite evidence; remaining unrelated RED lanes are expected.
```

## Known design facts

- Current Orchestrator uses one Codex executor thread for the entire approved plan.
- Existing `orchestrator-gc.sh` collects completed parent missions but is not yet a mandatory Phase 0 reconcile stage and does not model child-task resources.
- Child cleanup must include Codex task-list hygiene: archive the exact accepted
  child thread after integration/collection, compensate on later reconcile, and
  unarchive/rearchive the same thread if final review sends task-scoped rework.
- The Claude plugin has a Stop hook at 65%; Codex hook support must be proven independently.
- `orc/<mission>` and `orc/<mission>/<task>` cannot coexist as Git refs. Use `orc-task/<mission>/<task-id>` for children.

## Thread registry

| Lane | Thread ID | Status | Health evidence |
| --- | --- | --- | --- |
| Task 1 | `01a02652-1e30-7fe2-9beb-4dc9bca6d152` | checkpoint complete | Baseline green; four intentional RED contract lanes; installed Codex hook capability audited; ready set computed |
| Task 2 | `01a0265b-a983-7d43-a910-854214a24e4d` | active, verified | `create_thread` returned ID; title set successfully; `read_thread` found the exact ID/title and first turn `inProgress`; command evidence shows cwd `/Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-2`, full handoff/plan read, skills loaded, and focused `0/10` RED reproduced |
| Task 3 | `01a0265b-a77d-7163-9328-ade3fa5341e4` | active, verified | `create_thread` returned ID; title set successfully; `read_thread` found the exact ID/title and first turn `inProgress`; command evidence shows cwd `/Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-3` and handoff/plan reading began |
| Task 4 | `01a0265b-ab82-7970-856a-19da82a422a8` | active, verified | `create_thread` returned ID; title set successfully; `read_thread` found the exact ID/title and first turn `inProgress`; command evidence shows cwd `/Users/linhanyang/Documents/Daobrew/.worktrees/orchestrator-impl-task-4`, complete handoff/plan/skill/contract reads, and focused `1/13` RED reproduced |

No model or thinking override was requested, so `create_thread` intentionally
omitted both fields; the task API does not expose the resulting defaults and no
specific model/thinking setting is claimed as verified.
