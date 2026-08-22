# Orchestrator continuation {{REQUEST_ID}}

Resume the coordinator from the durable hub at `{{HUB}}`. This is one fresh project-local Codex task, not a fork and not a child executor restart.

## Exact authority binding

- Source coordinator task: `{{SOURCE_SESSION_ID}}`
- Coordinator session authority: `{{COORDINATOR_SESSION_AUTHORITY}}`
- Continuation request: `{{REQUEST_ID}}`
- Complete binding SHA-256: `{{STATE_SHA256}}`
- Carryover: `{{CARRYOVER_PATH}}`
- Carryover SHA-256: `{{CARRYOVER_SHA256}}`

Before acting, read the carryover and revalidate the exact mission, task
generation, durable state, and accepted child identities recorded by the
request. If any authority differs, mark the request stale and do not resume,
replace, or duplicate child execution.

Run Phase 0 reconcile, then continue only coordinator-owned scheduling,
integration, review, recovery, or mediation. Never restart an active child.

The exact source coordinator must record the provisional task through the
adapter with `--coordinator-session-id {{SOURCE_SESSION_ID}}`.
Accept it only after the Codex Loop Engineering health check proves creation,
exact list/read visibility, title, first turn, normal active/completed status,
startup evidence, and requested settings evidence. One failed provisional task
may have at most one replacement; exactly one health-checked task may receive
the accepted continuation receipt.

Immediately after acceptance, explicitly promote that exact accepted task into
coordinator authority:

```text
hooks/codex-continuation.sh --promote-coordinator \
  --hub "{{HUB}}" \
  --request-id "{{REQUEST_ID}}" \
  --coordinator-session-id "{{SOURCE_SESSION_ID}}" \
  --thread-id "<exact-accepted-thread-id>"
```

Promotion is receipt-bound and idempotent. It authorizes only the accepted
thread for the next coordinator boundary and durably supersedes the old
coordinator. No hidden filename convention or non-child inference may replace
this operation.

Promotion first publishes a private staged authority and exact intent; the
staged authority is inactive. Ownership changes only when one canonical,
regular, fsynced, atomic no-clobber `<request-id>.promotion-commit.json` marker
binds the old authority epoch, staged new authority, accepted receipt/thread,
request binding, and mission/task generation/state. Before `promotion-commit`
the old coordinator is the sole owner; after it the accepted coordinator is the
sole owner. Post-commit authority/supersession/promotion files are retriable
compatibility evidence and never control eligibility.
