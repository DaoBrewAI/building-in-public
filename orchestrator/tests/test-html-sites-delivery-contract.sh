#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/orchestrating/SKILL.md"
DELIVERY="$ROOT/skills/orchestrating/references/html-sites-delivery.md"
PLANNING="$ROOT/skills/orchestrating/references/planning-and-review.md"
MISSION="$ROOT/templates/MISSION.md"
README="$ROOT/README.md"
CODEX_MANIFEST="$ROOT/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@" >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}
contains() { grep -Fq -- "$2" "$1"; }
compact() { tr '\n' ' ' < "$1" | sed 's/[[:space:]][[:space:]]*/ /g' | grep -Fqi -- "$2"; }

check "HTML delivery is progressively disclosed" contains "$SKILL" \
  'references/html-sites-delivery.md'
check "delivery reference exists" test -s "$DELIVERY"
check "every user-facing HTML uses Sites" compact "$DELIVERY" \
  'Every HTML artifact presented to the user for preview, confirmation, approval, or status must be deployed through OpenAI Sites'
check "plan review is in delivery scope" contains "$DELIVERY" '`plan-review.html`'
check "status truth is in delivery scope" contains "$DELIVERY" '`status-truth.html`'
check "surfaced mission board is in delivery scope" compact "$DELIVERY" \
  '`board.html` whenever it is presented to the user'
check "internal HTML is not needlessly deployed" compact "$DELIVERY" \
  'HTML that remains purely internal and is never presented does not require deployment'

check "one mission-scoped Site owns stable routes" compact "$DELIVERY" \
  'one mission-scoped Site with stable `/plan`, `/status`, and `/board` routes'
check "canonical HTML remains source of truth" compact "$DELIVERY" \
  'canonical local HTML remains the source of truth'
check "published receipt binds content hash and URL" compact "$DELIVERY" \
  'record its source SHA-256, deployed Sites HTTPS URL, access mode, and successful deployment status'
check "updated HTML redeploys same URL" compact "$DELIVERY" \
  'redeploy the same route and keep the stable URL'

check "owner-only publication is automatic" compact "$DELIVERY" \
  'Owner-only Sites publication is pre-authorized and must not ask for another upload or deployment confirmation'
check "shared or public access still asks" compact "$DELIVERY" \
  'Changing to shared or public access requires explicit user approval'
check "Sites failure blocks human gate" compact "$DELIVERY" \
  'do not ask for `go`, approval, or acceptance from a local path'
check "local path is never primary delivery" compact "$DELIVERY" \
  'A local path, file attachment, artifact preview, or GitHub blob is never the primary HTML delivery'
check "coordinator owns Sites lifecycle" compact "$DELIVERY" \
  'The coordinator is the sole Site-owning agent'
check "planning worker does not publish" compact "$DELIVERY" \
  'Planning/review and implementation tasks only write their canonical artifacts and never invoke Sites'
check "Sites skills are explicit" compact "$DELIVERY" \
  'Use `sites:sites-building`, then `sites:sites-hosting`'

check "founder gate waits for deployed plan URL" compact "$SKILL" \
  'publish the current plan review through OpenAI Sites before entering the founder go gate'
check "acceptance produces status truth" compact "$SKILL" \
  'generate `status-truth.html` with `10x-engineer:status-truth`'
check "acceptance waits for status URL" compact "$SKILL" \
  'publish it through OpenAI Sites before any completion or acceptance claim'
check "planning correction triggers same-route redeploy" compact "$PLANNING" \
  'regenerate `plan-review.html`; the coordinator redeploys the same `/plan` route before asking for `go` again'
check "mission records cross-device URLs" contains "$MISSION" \
  '**Sites:** {{SITES_URLS}}'
check "README documents Sites-first HTML" compact "$README" \
  'Every user-facing HTML handoff uses an owner-only OpenAI Sites HTTPS URL'

check "Codex release is 0.5.4" bash -c \
  'version=$(jq -r .version "$1"); [[ "${version%%+*}" = 0.5.4 ]]' _ "$CODEX_MANIFEST"
check "Claude release is 0.5.4" bash -c \
  '[[ "$(jq -r .version "$1")" = 0.5.4 ]]' _ "$CLAUDE_MANIFEST"

echo "  html-sites-delivery-contract: $OK/$N"
[[ "$OK" -eq "$N" ]]
