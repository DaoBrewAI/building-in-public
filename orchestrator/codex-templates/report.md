# Report — {{MISSION_SLUG}}: {{TITLE}}

- **Branches:** {{per repo: branch + git log --oneline <base>..HEAD}}
- **Files changed:** {{per repo: git diff <base>...HEAD --stat}}

## TDD evidence
{{for every behavior change: failing test command + expected RED output, minimal implementation checkpoint, passing GREEN command + output; if the user explicitly approved a TDD exception, quote that approval and scope}}

## Code review
{{verdict from 10x-engineer:requesting-code-review + each Critical/Important/Minor finding and how it was resolved — paste the actual verdict, no summaries}}

## Verification
{{fresh commands run under 10x-engineer:verification-before-completion + raw pass/fail output per repo — paste real output, never "all passing"}}

## Deviations from the brief
{{anything done differently than specified, and why — "none" if none}}

## Suggested follow-ups (for the orchestrator, not for you to do)
{{tech debt noticed, adjacent bugs, ideas — or "none"}}

## Heartbeats
<!-- one-line timestamped progress notes appended during work -->
