# Durable coordinator continuation

Read this file completely before `PreCompact`, compact `SessionStart`, manual
continuation, provisional continuation health checks, or coordinator promotion.

## Eligibility

Only an exact authorized coordinator session with an eligible nonterminal
mission may publish continuation state. Completed, collected, failed, unrelated,
and accepted child sessions emit nothing. An `accepted` mission remains eligible
through `cleanup_pending`; it becomes terminal only when
`parent-cleanup-state=collected` and every child is both `collected` and
`task-window-state=archived`, with no window archival pending. Flush every
mission/task state, registry, decision, BLOCKED answer, report, and carryover
before recording.

## Immutable request

The hook writes request-scoped carryover under coordinator control;
`CARRYOVER.md` is only a human pointer. The request binds physical hub and
mission/task paths, coordinator authority, every relevant state/generation and
accepted child ID, exact bytes/hashes/device/inode/size, and carryover epoch.
It also binds sorted allowlisted file-record bundles for planning-stage
authority/import intent/receipts and for active broker, integration,
task-outcome, cleanup, task-window, and task-state-dir crash evidence. The
carryover prints a compact `active-intent` summary so the next coordinator can
resume an incomplete transaction before scheduling new work.
The request ID is the SHA-256 of that canonical binding.

Use private modes, no-follow component traversal, bounded same-fd reads,
no-clobber atomic publication, file and directory fsync, and immutable receipts.
Any symlink, escape, malformed authority, mutation, or state drift fails closed.
Equivalent manual/automatic triggers converge to the same request ID.

If `PreCompact` cannot prove carryover/request/receipt durability, return the
supported blocking response and do not allow compaction. Never restart, replace,
resume, or duplicate active child execution during carryover.

## New coordinator task

After compact `SessionStart` injects the request ID, persist any remaining
in-context knowledge and revalidate request/state/carryover hashes. Render the
continuation template and create one fresh project-local Codex task, not a fork.
Treat its ID as provisional.

Accept it only after exact list/read visibility, title, normal first turn,
startup evidence, and requested settings evidence. A failed provisional task is
stopped/archived and receives a durable rejection receipt; allow at most one
replacement. A second failure is terminal BLOCKED. Exactly one task can be
accepted for a request.

## Promotion

After health acceptance, call the hook's explicit coordinator-promotion mode
with source coordinator ID, request ID, and accepted thread ID. The same
crash-recoverable protocol lock covers accept/reject/promotion transitions.
Promotion publishes staged authority then one atomic no-clobber commit marker.
The old coordinator remains sole owner before that marker; the new coordinator
is sole owner after it. Retries converge without dual ownership.

An accepted or exhausted request is terminal. Later automatic/manual calls are
silent no-ops and never create another continuation. Manual continuation uses
the same protocol and never invents a context percentage.

## Implementation boundary

The hook supports Python 3.9 or newer. The exact Codex context percentage is unavailable.
A health-checked handoff publishes an accepted continuation receipt
before running `--promote-coordinator`; staged authority is inactive until the
atomic promotion marker commits ownership. When automatic delivery is
unavailable, the manual coordinator boundary uses the identical request,
health, acceptance, and promotion protocol.
