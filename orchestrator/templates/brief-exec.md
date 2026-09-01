# Mission {{MISSION_SLUG}}: {{TITLE}} — frozen execution contract

This coordinator-owned file is approval authority, not a worker prompt.
Implementation children receive only their rendered `task-brief.md` in visible
same-project native tasks.

## Ownership

- The coordinator computes the frozen DAG ready set, creates each native task,
  validates health, adopts its native worktree, persists outcomes, runs the
  broker, integrates verified tips, coordinates review, and performs final GC.
- One GPT-5.6-Sol child owns one DAG node and one retained worktree/thread. It
  never creates another task or writes mission/control/task-state files.
- The selected planning backend is read-only on product code and owns plan and
  review only.

## Execution boundary

- Approved design: `{{CONTROL_DIR}}/approved-design.md`
- Approved plan: `{{CONTROL_DIR}}/approved-plan.md`
- Approved DAG: `{{CONTROL_DIR}}/approved-task-dag.json`
- Every child may edit only its node's declared files in its native worktree.
- A child ends a turn with one `ORC_TASK_OUTCOME_V1` envelope. The coordinator
  alone imports external state and authors the identity-bound broker request.
- Commits, integration, and GC must verify the frozen four-file
  `approved.sha256` authority. No direct `git commit`, hidden executor, external
  writable-root receipt, or coordinator-context implementation is allowed.

## Mission constraints

Acceptance criteria:
{{ACCEPTANCE_CRITERIA}}

Non-goals:
{{NON_GOALS}}

Test commands:
{{TEST_COMMANDS}}

Accepted baseline failures:
{{ACCEPTED_FAILURES: adjudicated accepted-failure-set, or "none — attested baseline was fully green"}}

Context digest:
{{DIGEST: binding DECISIONS rulings, reference files/patterns per repo, known gotchas}}
