# Orchestrator risk-tiered 10x gates — implementation notes

- **Walkthrough quiz:** pending
- **Feature commit:** `8a5ddc7`
- **Review verdict:** approved after two local findings were resolved; no subagent was spawned because the active developer instruction forbids delegation unless the user explicitly requests it.

## Deviations

1. The initial plan described the risk gate in the skill only. Review added a deterministic `alignment-gate.sh` plus ten focused cases so missing coordinator evidence fails closed.
2. The worker-side plan contract was strengthened to require a standalone `plan-review.html`, not only `plan.md`.
3. `NEXT-STEPS.md` was moved fully under coordinator ownership and its final gate now rejects unclassified follow-ups.
4. Publication stops at a draft PR until the material-change walkthrough quiz passes and the user explicitly approves merge.

## Review findings resolved

- **Important:** provisioning `NEXT-STEPS.md` before launch allowed a worker to edit coordinator-owned authority state. Fixed by instantiating it only after the worker is dead in acceptance.
- **Important:** the final gate accepted arbitrary non-template next-step prose. Fixed by requiring every table row to use `ready`, `decision-needed`, or `deferred`, or an explicit `None`.
- **Minor:** ShellCheck treated intentionally delayed `eval` assertions as unused/unexpanded. Added narrow test-only suppressions; production scripts remain zero-warning.

## Fresh verification

- Source adoption contract: PASS.
- Source orchestrator suite: alignment 10/10; pipeline 15/15; commit broker PASS; worker lifecycle PASS.
- Installed orchestrator suite: same results.
- Skill validator: PASS in both source and installed copies.
- ShellCheck: PASS for changed scripts and tests.
- Source/installed orchestrator directory diff: exact match.
