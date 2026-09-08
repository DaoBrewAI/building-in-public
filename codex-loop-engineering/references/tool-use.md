# Tool and computer use

Apply to connector, browser/native-app, media-tool and long-running-call work.
This reference does not create permissions or a new computer-use backend.

## Match the surface to the outcome

Prefer an available connector/API/CLI for structured reads and precise updates.
Use the real UI when requested or when acceptance depends on seeing/operating it.
Discover capabilities before guessing parameters.

Batch independent reads. Stateful edits, account actions, dependencies and
approvals remain ordered. Use async only when exposed; preserve request IDs and
await actual results. Do not copy Responses API `async` fields into other tools.

Observe relevant state before each UI decision and verify the smallest meaningful
result after an action. Do not reuse stale element IDs, invent selectors, reload
the same failure indefinitely or search guessed URL variants. Tool availability
does not prove content consumption or successful action.

## Preserve the permitted browser/account

Read the current user/project browser rule. An existing-profile requirement
means verify executable, user-data directory and profile identity before use;
a friendly tool label or icon may not distinguish multiple instances.

- Reuse the permitted existing related window/tab. Do not substitute a temporary,
  isolated, testing or headless browser when the required instance is inaccessible.
- Avoid app-entry tools that may auto-launch before the existing instance is
  established. Use supported discovery or read-only process inspection first.
- A rule covering render workflows applies to headless rendering too. Do not
  improvise a renderer inside a personal session or move it elsewhere to evade
  the restriction. Report the actual design conflict.
- Fallback/native control must be allowed by both the user and active tool rules.
  Do not enable security permissions, share credentials or change browser settings
  without the required authority.
- Cleanup targets only an explicitly authorized, identified extra process and
  its startup owner. Never blanket-kill browsers, delete profiles or reset login.

GPT-6's stronger computer use does not change these boundaries.

## Classify failure before retrying

Distinguish configuration, identity/authorization, usage/resource, transport,
malformed output, unsupported operation and product bugs. Retry only a classified
transient failure, within the node's allowance and without replaying a completed
external action.

Access checks are separate: entry/origin -> identity-provider login -> product
admission/tenant binding -> source permission/readability -> feature/output.
Record actual source/build/process/config identity. A source HEAD may differ
from code loaded in a long-running process; local success is not deployed proof.
Use protected references, never credential values in reports.

## Evidence must support the particular claim

URLs/snippets establish discovery. A transcript supports speech/text. Sampled
frames support only inspected content. Exact timing, audio or complete coverage
requires appropriate evidence. Use media tools/frames/transcripts when the model
does not natively accept the source modality.

Record observable results and safe evidence refs, not private raw reasoning.
Separate coverage, inference and recommendation. A repeated model claim is not
independent verification.

## Efficient close-out

Wait for real completion without narrating unchanged polls. Preserve last-good
artifacts. Once required checks pass, repeat/expand only for new changes or risk.
Report outcome and next gate rather than raw logs. User interruptions steer the
active work; don't let queued actions perform an abandoned intent.
