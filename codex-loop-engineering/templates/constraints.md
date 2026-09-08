# {{PROJECT_NAME}}: constraints

## Scope and execution

- Follow the current user's requested mode and phase set; plan/review is not execution.
- Preserve pre-existing work and explicit product/runtime/browser boundaries.
- Use one Supervisor and one integrator; declare worker write ownership and exclusive resources.
- Record actual source, loaded build and evidence; do not collapse tests with live behavior.

## Session policy

- Preserve the user's supervisor reasoning choice.
- Default cross-module diagnosis/integration to gpt-6-astra medium; bounded,
  frozen-interface implementation may use gpt-5.6-sol high.
- Standard/non-Fast is the default for all new sessions, day and night.
- Request service_tier=default and Fast=false where supported. Verify actual
  launch state; if unobservable, hold mutations and report the limitation.
- Ultra/max workers and Fast require explicit scoped user overrides. Do not
  inherit them from the parent or an old template.
- Start with at most two execution workers; split oversized checkpoints.

## Tools and budget

- Use available supported APIs/tools; verify meaningful output after actions.
- Respect existing-profile/browser rules across CLI, QA and rendering. Never
  start an alternate browser as a substitute for an inaccessible permitted one.
- Define bounded retries, time and any approved token/provider budget per node.
- Missing authority, credentials/data, unsupported runtime, exhausted budget or
  out-of-scope/destructive action stops the dependent lane.

## Git and publication

- Commit, push, merge and deploy only within current explicit authorization.
- Do not rewrite shared history or alter unrelated branches.
- A worktree is a checkout; record its actual branch or detached ref.
- Preserve coherent collaborator changes; do not partially transplant a coupled migration.
