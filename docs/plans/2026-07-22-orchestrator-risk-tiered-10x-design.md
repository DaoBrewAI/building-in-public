# Orchestrator risk-tiered 10x gates — design

## Goal

Make every Codex-orchestrated mission use one durable 10x workflow from design
through merge, with HTML reports that let the user understand the implementation
and distinguish code state from witnessed runtime evidence.

## Selected approach

Use a risk-tiered merge gate.

Every mission must follow this order:

1. `10x-engineer:brainstorming` and `10x-engineer:writing-plans`;
2. `10x-engineer:test-driven-development` during implementation;
3. `10x-engineer:requesting-code-review`, with all Critical and Important
   findings resolved;
4. `10x-engineer:verification-before-completion`, using fresh full-suite
   evidence;
5. a brokered feature commit;
6. `10x-engineer:status-truth` rendered as durable pre-merge HTML;
7. merge and merged-tree verification;
8. final durable status-truth HTML and next-step handoff.

Every mission is classified `routine` or `material` in `MISSION.md`. Material
means user-visible behavior, authentication/security/privacy, stored-data or
migration semantics, public/cross-component contracts, production/infra/IAM,
cost, release artifacts, or a long autonomous implementation. Uncertainty is
material.

Material missions additionally use `10x-engineer:change-walkthrough` after code
review. The mission enters `awaiting-alignment`; the coordinator publishes the
walkthrough and pre-merge status report, immediately notifies the user, and
waits for the walkthrough quiz plus explicit merge approval. Routine missions
still produce the status HTML but may merge automatically after all gates pass.

## Durable artifacts

Every accepted mission keeps `status-truth-premerge.html`, `status-truth.html`,
`coordinator-acceptance.md`, and `NEXT-STEPS.md`. Material missions also keep
`change-walkthrough.html` and record the quiz result. The task board links these
files and displays the risk class and active workflow gate.

Status truth remains conservative: tests do not become witnessed-live evidence.
Green requires a matching running/build SHA plus an attached observation.

## Enforcement

- The worker brief and report template name the required 10x skills and evidence.
- The deterministic pipeline gate rejects review handoff when plan, TDD, review,
  verification, deviation, or follow-up evidence is missing.
- Coordinator-only artifacts are checked after the brokered commit and before
  merge, because status truth needs a feature SHA.
- The skill forbids merge when HTML evidence or a required human-alignment gate
  is missing.
- `NEXT-STEPS.md` classifies every follow-up as `ready`, `decision-needed`, or
  `deferred`; existing pre-authorized pending missions may then be released.

## Non-goals

- Do not make every mission wait for a human.
- Do not mark tests as live runtime evidence.
- Do not let workers write coordinator artifacts or Git metadata.
- Do not change the existing sandbox, trusted-manifest, or brokered-commit
  security boundaries.
