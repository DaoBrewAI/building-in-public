# Cross-device HTML delivery

Read this file before presenting any mission HTML to the user. The coordinator
is the sole Site-owning agent. Planning/review and implementation tasks only
write their canonical artifacts and never invoke Sites.

## Scope

Every HTML artifact presented to the user for preview, confirmation, approval,
or status must be deployed through OpenAI Sites. This includes:

- `plan-review.html` at the founder `go` gate;
- `status-truth.html` after implementation and final verification; and
- `board.html` whenever it is presented to the user.

Apply the same rule to any future user-facing HTML. HTML that remains purely
internal and is never presented does not require deployment.

## One Site, stable routes

Use one mission-scoped Site with stable `/plan`, `/status`, and `/board` routes.
The canonical local HTML remains the source of truth; the Site is its
cross-device reading surface. Adapt the exact validated HTML into the Site
without changing its claims, decisions, evidence markers, or visual meaning.
Use `sites:sites-building`, then `sites:sites-hosting`.

When a canonical HTML file changes, rebuild and redeploy the same route and keep
the stable URL. Never create a replacement Site merely because the plan was
corrected or status evidence advanced.

After a successful deployment, atomically update coordinator-owned
`control/<mission>/sites-delivery.json`. For each published route, record its
canonical source path. Also record its source SHA-256, deployed Sites HTTPS URL,
access mode, and successful deployment status. A receipt is current only when
its source hash matches the bytes being presented. Preserve the Sites project ID and
deployment metadata in the Site checkout, not in product worktrees.

## Access and authorization

Owner-only Sites publication is pre-authorized and must not ask for another
upload or deployment confirmation. It is the default so the same signed-in user
can open the result on phone or computer. Changing to shared or public access
requires explicit user approval that names the resolved audience.

Before upload, remove credentials, tokens, OAuth values, personal/customer data,
private corpora, and unrelated material. If required content cannot be safely
published, stop and explain the exact blocker instead of silently weakening the
report.

## Human gates and failure behavior

Do not present an HTML handoff until Sites reports a successful deployment and
the current receipt matches the canonical source hash. Return the Sites HTTPS
URL as the primary link. A local path, file attachment, artifact preview, or
GitHub blob is never the primary HTML delivery; a local path may appear only as
secondary desktop evidence.

If Sites tools, authorization, build, or deployment are unavailable, preserve
the canonical HTML and mission state, record `sites-publish-unavailable`, and do
not ask for `go`, approval, or acceptance from a local path. Retry only a
plausibly transient failure. Never substitute an unhosted file or another
hosting provider without explicit user direction.
