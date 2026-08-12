# Report — {{MISSION_SLUG}}: {{TITLE}}

- **Branches:** {{per repo: branch + git log --oneline <base>..HEAD}}
- **Files changed:** {{per repo: git diff <base>...HEAD --stat}}

## Code review
{{Fable same-session review verdict + each finding and how it was resolved — paste the actual verdict, no summaries}}

## Verification
{{commands run + raw pass/fail output per repo — paste real output, never "all passing"}}

## Deviations from the brief
{{anything done differently than specified, and why — "none" if none}}

## Suggested follow-ups (for the orchestrator, not for you to do)
{{tech debt noticed, adjacent bugs, ideas — or "none"}}

## Heartbeats
<!-- one-line timestamped progress notes appended during work -->
