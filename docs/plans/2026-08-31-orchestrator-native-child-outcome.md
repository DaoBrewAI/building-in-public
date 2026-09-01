# Orchestrator 0.5.4 Native Lifecycle Implementation Plan

## Completed work

1. Replace external writable-root receipt with coordinator-owned native health,
   exact saved-project identity, frozen schedule base, bounded attempts, and
   rejected-task archive evidence.
2. Make production child ownership `create_thread → health → adopt` only;
   retain `create` solely as a temp test-fixture operation and remove production
   reprovision.
3. Import strict terminal outcomes in the coordinator, rotate rework
   generation/nonce on the retained child, and keep the immutable ledger.
4. Gate the resident broker on a completed outcome epoch; bind mode, content,
   path scope, task identity, and frozen approval authority.
5. Replace ordinary merge/commit hooks with verified merge tree, `commit-tree`,
   ref CAS, exact-tree verification, and crash recovery.
6. Stage Codex-Ultra planning outputs with per-turn nonce, prior state, durable
   intent/receipt, and recoverable cleanup.
7. Bind every active lifecycle artifact into continuation and keep accepted
   cleanup eligible until exact terminal collection.
8. Retain all children through review/rework; archive first and batch-GC only
   after clean final review and acceptance. Require exact DAG/registry,
   integration, task-state, project, and frozen hash authority.
9. Serialize coordinator mutations with one mission-scoped lifecycle lock.
10. Run focused suites, complete suite, dual-host validators, independent
    Critical/Important review, real Desktop canary, direct main push, and
    Codex/Claude reinstall verification.

## Release gate

- Orchestrator suite and shared adoption contract exit 0 from a clean candidate.
- Plugin and both skill validators pass.
- Real native canary proves sidebar visibility, exact project ID, independent
  worktree/context, terminal wait result, archive, and host worktree release.
- `origin/main`, marketplace checkout, Codex cache, and Claude user install all
  resolve to the same 0.5.4 commit/version.
