#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
MEDIATION="$ROOT/skills/orchestrator-mediation/SKILL.md"

N=0
OK=0
check() {
  local label="$1" file="$2" literal="$3"
  N=$((N + 1))
  if tr '\n' ' ' < "$file" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$literal"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

check "Fable selection authorizes least-scope planning and review" "$SKILL" 'Selecting `fable-opus` authorizes `auto-least-scope` Fable/Opus planning and review'
check "auto mode uses a nonblocking notice" "$SKILL" 'Give this nonblocking notice once after selection, then continue'
check "approval-required needs explicit user selection" "$SKILL" 'unless the user explicitly selected `approval-required`'
check "no-external needs explicit prohibition" "$SKILL" 'only when the user explicitly forbids Fable/Opus'
check "task-relevant source and tests are covered" "$SKILL" 'task-relevant source, build configuration, and tests'
check "credentials and personal data are excluded" "$SKILL" 'credentials, tokens, OAuth values, personal/customer data'
check "private corpora and unrelated files are excluded" "$SKILL" 'ignored/private corpora, and unrelated files'
check "excluded material is sanitized without a pause" "$SKILL" 'Sanitize and continue'
check "generic caution cannot invent a gate" "$SKILL" 'A concrete host/tool denial is authoritative; generic caution is not'
check "same-scope transitions are not reauthorized" "$SKILL" 'Never reauthorize the same least-scope stage after a new chat, reauthentication, resume, review transition, or Fable→Opus quota fallback'
check "Codex selection avoids external planning" "$SKILL" 'Selecting `codex-ultra` never invokes Fable/Opus or emits the external-planning notice'
check "mediation auto-resolves false privacy blockers" "$MEDIATION" 'resolve it without asking the user'
check "mediation requires concrete host denial" "$MEDIATION" 'current turn contains a concrete tool or host denial'

echo "  external-planning-policy-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
