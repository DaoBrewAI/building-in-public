#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-$(basename "$PWD")}"
LOOP_DIR="${LOOP_DIR:-docs/loop}"
AUTO_CHAIN="${AUTO_CHAIN:-false}"
OVERWRITE="${OVERWRITE:-false}"

GOAL_FILE="$LOOP_DIR/goal.md"
TRACKER_FILE="$LOOP_DIR/tracker.md"
CONSTRAINTS_FILE="$LOOP_DIR/constraints.md"
HANDOFF_FILE="$LOOP_DIR/handoff.md"
WROTE_FILES=()

write_file() {
  local path="$1"

  if [[ -e "$path" && "$OVERWRITE" != "true" ]]; then
    echo "Skipped existing file: $path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  cat > "$path"
  WROTE_FILES+=("$path")
  echo "Wrote: $path"
}

if [[ ! -d ".git" ]]; then
  echo "Warning: no .git directory found. Run this from the root of the project repo Codex should work on."
fi

mkdir -p "$LOOP_DIR"

write_file "$GOAL_FILE" <<'EOF'
# Goal

## Objective

Complete <specific outcome>.

## Done When

- <evidence that proves the outcome>
- <tests, builds, screenshots, benchmarks, or artifacts that must pass or exist>
- <user-facing behavior that must be true>

## Non-Goals

- Do not <out-of-scope change>.
- Do not <risky expansion>.

## Read First

- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md
- <project-specific file, issue, log, screenshot, design note, or API spec>
EOF

write_file "$TRACKER_FILE" <<'EOF'
# Loop Tracker

## Status Legend

- [ ] not started
- [~] in progress
- [x] complete
- [!] blocked

## Phases

| Phase | Status | Goal | Verification | Notes |
| --- | --- | --- | --- | --- |
| 1 | [ ] | Map current state | Evidence links added | |
| 2 | [ ] | Implement first coherent slice | Tests/build pass | |
| 3 | [ ] | Harden edge cases | Regression coverage | |
| 4 | [ ] | Final review and docs | Full checklist pass | |

## Current Next Action

Start with Phase 1. Update this section after every checkpoint.

## Evidence Log

| Checkpoint | Verification Run | Result | Notes |
| --- | --- | --- | --- |
| | | | |
EOF

write_file "$CONSTRAINTS_FILE" <<'EOF'
# Constraints

## Product Constraints

- Preserve <user flow, API contract, visual behavior, launch narrative, or public interface>.

## Engineering Constraints

- Follow existing repo patterns before adding new abstractions.
- Keep commits scoped to one coherent checkpoint.
- Do not touch unrelated files.
- Prefer tests and verification over claims of completion.

## Safety Constraints

- Stop before using production credentials, deleting user data, changing billing, or deploying.
- Ask for approval before irreversible external actions.

## Budget Constraints

- Stop after <time, token, cost, or attempt limit> if the goal is not yet verifiable.

## Git Constraints

- Commit only after verification.
- Keep commit messages specific to the checkpoint.
- Do not rewrite shared history unless the user explicitly asks.
EOF

if [[ -e "$HANDOFF_FILE" && "$OVERWRITE" != "true" ]]; then
  echo "Skipped existing file: $HANDOFF_FILE"
else
  mkdir -p "$(dirname "$HANDOFF_FILE")"
  {
    cat <<'EOF'
# Loop Handoff

## Current State

- Branch:
- Last checkpoint:
- Last verification:
- Known risks:

## Next Step

Execute the next unchecked item in `docs/loop/tracker.md`.

## Commands Already Run

```bash
# paste recent verification commands here
```

## Blockers

- None, or describe exactly what input is needed.

## Auto-Chain Permission

EOF
    printf 'auto_chain_next_session: %s\n\n' "$AUTO_CHAIN"
    cat <<'EOF'
If true and the Codex environment supports creating the next session, Codex may create a project-local continuation session after it:

- updates tracker and handoff
- runs verification
- commits and pushes the checkpoint
- confirms unchecked work remains
- confirms no blocker needs human approval, credentials, or external data

## Continuation Session Health Check

A returned thread ID is provisional until verified. After creating the next Codex session:

1. Confirm `list_threads` or `read_thread` can find the returned ID or exact title.
2. Rename the thread to the planned checkpoint title.
3. Confirm `read_thread` shows the first turn exists and is active or completed normally.
4. Only then record the thread ID in `tracker.md`, `handoff.md`, and the final response.

If the ID is not visible, title updates fail repeatedly, or the thread becomes unreadable/unopenable, do not treat it as the next session. Mark the stale ID in the handoff if needed, create one replacement session, verify it, and record only the verified replacement ID.
EOF
  } > "$HANDOFF_FILE"
  WROTE_FILES+=("$HANDOFF_FILE")
  echo "Wrote: $HANDOFF_FILE"
fi

if [[ "$LOOP_DIR" != "docs/loop" && "${#WROTE_FILES[@]}" -gt 0 ]]; then
  export LOOP_DIR
  for path in "${WROTE_FILES[@]}"; do
    perl -0pi -e 's{docs/loop}{$ENV{LOOP_DIR}}g' "$path"
  done
fi

cat <<EOF

Codex loop setup installed for: $PROJECT_NAME

Created under: $LOOP_DIR

Next steps:
1. Edit $GOAL_FILE with the real objective and done criteria.
2. Edit $TRACKER_FILE with the real phases.
3. Edit $CONSTRAINTS_FILE with project-specific boundaries.
4. Start Codex with:

/goal Complete the objective in $GOAL_FILE.

First read:
- $GOAL_FILE
- $TRACKER_FILE
- $CONSTRAINTS_FILE
- $HANDOFF_FILE

Then execute the next unchecked tracker item. Work in coherent checkpoints.
After each checkpoint, run verification, update tracker and handoff, inspect the diff,
commit the checkpoint, and continue only if the next step is still in scope.

Stop when the goal is verified, a blocker needs human input, or the budget is reached.
EOF
