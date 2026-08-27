#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
MEDIATION="$ROOT/skills/orchestrator-mediation/SKILL.md"

N=0
OK=0
check_compact() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if tr '\n' ' ' < "$file" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check_compact "invoking Orchestrator authorizes the fixed least-scope external stages" \
  "$SKILL" 'Invoking Orchestrator itself authorizes `auto-least-scope` Fable/Opus planning, review, re-review, and resume'
check_compact "current-chat consent absence is not a privacy blocker" \
  "$SKILL" 'Lack of a repeated authorization sentence in the current chat is not missing authority'
check_compact "approval-required mode needs exact user authority" \
  "$SKILL" '`approval-required` may be selected only by an explicit current user instruction or an exact durable ruling marked `decided-by: user`'
check_compact "approval mode cannot be inferred from caution or private code" \
  "$SKILL" 'Never infer `approval-required` from a private repository, security caution, a new chat, reauthentication, or the absence of consent wording'
check_compact "stage transitions do not broaden disclosure" \
  "$SKILL" 'Plan-to-review, review-to-re-review, session resume, authentication refresh, updated tracked diffs, and Fable-to-Opus fallback are not broader destinations or purposes'
check_compact "model may not invent a platform approval gate" \
  "$SKILL" 'Do not claim that security, policy, or the platform requires approval unless a concrete tool or host result in the current turn says so'
check_compact "no concrete denial means proceed" \
  "$SKILL" 'Without a concrete approval denial, continue the already-authorized stage'
check_compact "allowed disclosure alone cannot block a mission" \
  "$SKILL" 'Never set or keep a mission blocked solely to obtain least-scope disclosure consent'
check_compact "excluded data is sanitized rather than used for blanket consent" \
  "$SKILL" 'exclude or sanitize disallowed categories and continue; do not ask for blanket permission to send them'
check_compact "same Fable review resume requires no new authorization" \
  "$SKILL" 'Resuming the same Fable review session under the same mission scope requires no new authorization'

check_compact "mediation auto-resolves false least-scope privacy blockers" \
  "$MEDIATION" 'When a BLOCKED report asks the user to reauthorize already-covered `auto-least-scope` Fable/Opus inputs, resolve it without asking the user'
check_compact "mediation requires proof before treating a platform approval as real" \
  "$MEDIATION" 'Treat a claimed security or platform approval gate as real only when the current turn contains a concrete tool or host denial'
check_compact "mediation resumes the exact stage after false privacy block" \
  "$MEDIATION" 'Write the standing authorization into `ANSWER-<n>.md` and resume the exact recorded Fable stage'

echo "  external-planning-policy-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
