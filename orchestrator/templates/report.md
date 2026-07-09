# Report — {{TASK_ID}}: {{TITLE}}

- **Branch:** {{BRANCH}}
- **Commits:** {{git log --oneline main..HEAD}}
- **Tests:** {{command run + raw pass/fail counts — paste real output, no summaries like "all passing"}}
- **Files changed:** {{git diff main...HEAD --stat}}

## Deviations from the brief
{{anything done differently than specified, and why — "none" if none}}

## Suggested follow-ups (for the orchestrator, not for you to do)
{{tech debt noticed, adjacent bugs, ideas — or "none"}}

## Heartbeats
<!-- one-line timestamped progress notes appended during work -->
