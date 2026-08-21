#!/usr/bin/env bash
# RED contract for coordinator-owned child scheduling and thread health checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
TASK_BRIEF="$ROOT/templates/task-brief.md"

N=0
OK=0
check_contains() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if [[ -f "$file" ]] && grep -Fqi -- "$literal" "$file"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

section_text() {
  local file="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    index($0, start) { inside = 1; next }
    inside && index($0, end) { exit }
    inside { print }
  ' "$file" \
    | tr '\n' ' ' \
    | sed 's/<!--[^>]*-->//g; s/[[:space:]][[:space:]]*/ /g'
}

check_section_contains() {
  local label="$1" file="$2" start="$3" end="$4" literal="$5" content
  N=$((N + 1))
  content="$(section_text "$file" "$start" "$end")"
  if printf '%s\n' "$content" | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_section_excludes() {
  local label="$1" file="$2" start="$3" end="$4" literal="$5" content
  N=$((N + 1))
  content="$(section_text "$file" "$start" "$end")"
  if ! printf '%s\n' "$content" | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_section_order() {
  local label="$1" file="$2" start="$3" end="$4" first="$5" second="$6" content
  N=$((N + 1))
  content="$(section_text "$file" "$start" "$end")"
  if printf '%s\n' "$content" | awk -v first="$first" -v second="$second" '
    {
      text = tolower($0)
      first_at = index(text, tolower(first))
      second_at = index(text, tolower(second))
      if (first_at > 0 && second_at > first_at) found = 1
    }
    END { exit(found ? 0 : 1) }
  '; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_contains "only coordinator may create child threads" "$SKILL" "only the coordinator"
check_contains "child threads may not create grandchildren" "$SKILL" "never create grandchildren"
check_section_contains "ready set requires every predecessor durably completed and integrated" \
  "$SKILL" "### Compute the ready set" "### Create and accept child threads" \
  "every predecessor is durably completed and verified integrated"
check_section_contains "ready set recomputes after integration before dependent scheduling" \
  "$SKILL" "### Compute the ready set" "### Create and accept child threads" \
  "recompute the ready set after every verified integration and before scheduling any dependent task"
check_section_excludes "ready set rejects the weaker completion-only predecessor rule" \
  "$SKILL" "### Compute the ready set" "### Create and accept child threads" \
  "every predecessor is completed and recorded durably"
check_contains "ready set excludes an existing owner" "$SKILL" "no active or completed owner"
check_contains "ready set excludes file and contract conflicts" "$SKILL" "file or contract conflict"
check_contains "ready set excludes user approval blockers" "$SKILL" "user-approval blocker"
check_contains "child execution uses fresh project-local Codex threads" "$SKILL" "fresh project-local Codex threads"
check_contains "thread IDs stay provisional until health checks pass" "$SKILL" "provisional"
check_contains "health check verifies list or read visibility" "$SKILL" "list or read"
check_contains "health check verifies first-turn startup evidence" "$SKILL" "startup evidence"
check_contains "failed health check allows at most one replacement" "$SKILL" "one replacement"
check_contains "child task brief persists durable task outcomes" "$TASK_BRIEF" "durable task state"
check_contains "child task brief forbids child scheduling" "$TASK_BRIEF" "never create child tasks"

check_section_contains "rework reprovisions the exact manifest worktree and branch" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "re-provision the task's exact manifest-recorded worktree path and branch from the updated parent tip"
check_section_contains "rework preserves the accepted sandbox root" \
  "$SKILL" '- `rework`:' '- `blocked`:' "using the same sandbox root"
check_section_contains "rework records the new generation and base" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "record the new generation and base SHA in the authoritative task registry"
check_section_contains "rework resumes the same thread only after reprovision records" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "only after those records are durable, resume the same accepted child thread"
check_section_contains "rework never resumes against a collected or missing worktree" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "never resume against a collected or missing worktree"
check_section_contains "rework preserves legacy single-executor fallback" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "if no task registry or task identity exists, use the explicit legacy single-executor fallback"
check_section_contains "exec BLOCKED preserves legacy single-executor fallback" \
  "$SKILL" '- exec:' 'Never leave a material blocker' \
  "if no task registry or task identity exists, use the explicit legacy single-executor fallback"
check_section_contains "task brief has an authoritative sandbox roots placeholder" \
  "$TASK_BRIEF" '## Authoritative inputs' '## Exact task contract' \
  "{{SANDBOX_ROOTS}}"
check_section_contains "task brief rejects every unlisted writable root" \
  "$TASK_BRIEF" '## Authoritative inputs' '## Exact task contract' \
  "no other writable roots are permitted"

check_section_contains "thread archival waits for integration and exact collection" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "after durable verified integration and exact child worktree and branch collection"
check_section_contains "thread archival targets the accepted child ID" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "archive the exact accepted child thread"
check_section_contains "thread archival excludes unsafe task states" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "Never archive running, blocked, review, or unresolved-rework"
check_section_contains "thread archive API failure is journaled" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "task-window archive failure"
check_section_contains "thread archive API failure is retriable cleanup" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "cleanup_pending"
check_section_contains "repeat thread archival is idempotent" \
  "$SKILL" '### Archive collected child task windows' '## Phase 4' \
  "repeated archival is idempotent"
check_section_contains "rework unarchives the accepted child before reprovision" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "unarchive the exact accepted child thread"
check_section_order "rework unarchive precedes worktree reprovision" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "unarchive the exact accepted child thread" \
  "re-provision the task's exact manifest-recorded worktree path and branch"
check_section_order "rework reprovision precedes same-thread resume" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "re-provision the task's exact manifest-recorded worktree path and branch" \
  "resume the same accepted child thread"
check_section_contains "rework rearchives only after renewed integration and collection" \
  "$SKILL" '- `rework`:' '- `blocked`:' \
  "rearchive only after verified reintegration and exact worktree and branch collection"

echo "  child-thread-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
