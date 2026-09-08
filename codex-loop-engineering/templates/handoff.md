# {{PROJECT_NAME}}: handoff

mode: plan
execution_authorized: false
auto_chain_next_session: {{AUTO_CHAIN}}

## Current state

- Repo/worktree/base ref:
- Loaded runtime/frontend where relevant:
- Installed skill version/content:
- Last accepted checkpoint/evidence:
- Authorized phase set and excluded actions:
- Active/provisional task IDs and resource reservations:

## Next checkpoint

Read {{LOOP_DIR}}/goal.md, tracker.md, constraints.md and this handoff. Reconcile
the current mode before acting. Auto-chain permits continuation only within the
user-authorized scope; it does not convert plan/review into execution.

## Session and evidence gate

Declare model, reasoning, Standard/non-Fast tier, cwd/base and ownership before
launch. Verify the actual task ID, first turn, settings and contract read before
allowing implementation. An unverified ID remains provisional. Stop wrong-setting
workers before side effects; at most one replacement after resolving the cause.

## Completed actions and blockers

Record commands/results and exact remaining gates. Preserve last-good artifacts.
Workers report; the Supervisor accepts and releases successors. Do not restore
old controllers or duplicate an active node.

## Continuation packet

Fill the single next node's outcome, source/contracts, owned files/resources,
acceptance, settings, limits and output location before an authorized handoff.
