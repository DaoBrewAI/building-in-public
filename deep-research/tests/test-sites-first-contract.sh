#!/usr/bin/env bash
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill_root="$plugin_root/skills/deep-research"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_text() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  rg -q --ignore-case "$pattern" "$file" || fail "$message"
}

reject_text() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if rg -q --ignore-case "$pattern" "$file"; then
    fail "$message"
  fi
}

require_absent() {
  local path="$1"
  local message="$2"
  [[ ! -e "$path" ]] || fail "$message"
}

manifest="$plugin_root/.claude-plugin/plugin.json"
codex_manifest="$plugin_root/.codex-plugin/plugin.json"
skill="$skill_root/SKILL.md"
mobile="$skill_root/references/mobile_delivery.md"
reporting="$skill_root/references/reporting.md"
readme="$plugin_root/README.md"
marketplace="$plugin_root/../.claude-plugin/marketplace.json"

require_text "$manifest" '"version"[[:space:]]*:[[:space:]]*"1\.1\.0"' \
  'plugin version must be 1.1.0'
require_text "$manifest" 'OpenAI Sites' \
  'plugin description must advertise OpenAI Sites delivery'
require_text "$codex_manifest" '"version"[[:space:]]*:[[:space:]]*"1\.1\.0"' \
  'Codex plugin version must be 1.1.0'
require_text "$codex_manifest" 'OpenAI Sites' \
  'Codex plugin description must advertise OpenAI Sites delivery'
require_text "$marketplace" '"name"[[:space:]]*:[[:space:]]*"deep-research"' \
  'marketplace must still register Deep Research'
require_text "$marketplace" 'OpenAI Sites' \
  'marketplace description must advertise OpenAI Sites delivery'

require_text "$skill" 'OpenAI Sites' \
  'SKILL.md must route canonical HTML reports to OpenAI Sites'
require_text "$skill" 'owner-only' \
  'SKILL.md must define owner-only as the default audience'
require_text "$skill" 'selected users|workspace|public|anyone on the internet' \
  'SKILL.md must define broader sharing audiences'
require_text "$skill" 'explicit approval|confirm.*audience|approval.*audience' \
  'SKILL.md must require confirmation before broader sharing'
require_text "$skill" 'Do not generate a PDF by default' \
  'SKILL.md must keep PDF generation opt-in'
reject_text "$skill" 'private GitHub delivery' \
  'SKILL.md description must not present private GitHub as the delivery surface'

require_text "$mobile" 'OpenAI Sites.*default|default.*OpenAI Sites' \
  'mobile delivery must make OpenAI Sites the default reading surface'
require_text "$mobile" 'owner-only' \
  'mobile delivery must default to owner-only access'
require_text "$mobile" 'Sites HTTPS|HTTPS.*Sites' \
  'mobile delivery must return a cross-device Sites HTTPS URL'
require_text "$mobile" 'explicit approval|confirm.*audience|approval.*audience' \
  'mobile delivery must gate broader sharing on explicit audience approval'

require_text "$reporting" 'OpenAI Sites' \
  'reporting workflow must publish through OpenAI Sites'
require_text "$reporting" 'Sites HTTPS|HTTPS.*Sites' \
  'reporting workflow must return the Sites HTTPS URL first'
python3 - "$reporting" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
graphify = text.index("### Step 2: Verify Graphify retrieval")
publish = text.index("### Step 3: Publish a mobile reading URL")
if graphify >= publish:
    raise SystemExit("FAIL: reporting must verify Graphify before Sites publication")
PY
require_text "$readme" 'OpenAI Sites' \
  'README must document Sites-first delivery'
require_absent "$skill_root/templates/private-html-preview.yml" \
  'obsolete GitHub Actions preview template must not ship with Sites-first delivery'

if rg -q --ignore-case \
  'private GitHub delivery|companion PDF|PDF blob|private-html-preview|private GitHub artifact' \
  "$skill" "$mobile" "$reporting" "$readme"; then
  fail 'primary instructions must not retain the obsolete GitHub/PDF delivery path'
fi

printf 'PASS: Deep Research Sites-first delivery contract\n'
