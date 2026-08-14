#!/usr/bin/env bash
# Tests for scripts/install-worker-settings.sh — guarded local Claude settings.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-worker-settings.sh"
TEMPLATE="$ROOT/templates/worker-settings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

N=0
OK=0
check() {
  local label="$1"
  shift
  N=$((N + 1))
  if "$@"; then
    OK=$((OK + 1))
  else
    echo "  case $N failed: $label"
  fi
}

fails_quietly() {
  ! "$@" >/dev/null 2>&1
}

new_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  mkdir -p "$repo/.claude"
  printf '%s\n' '{"enabledPlugins":{"10x-engineer@building-in-public":true}}' > "$repo/.claude/settings.json"
  git -C "$repo" add .claude/settings.json
  git -C "$repo" commit -qm base
}

run_installer() {
  local repo="$1"
  "$INSTALLER" \
    --worktree "$repo" \
    --template "$TEMPLATE" \
    --worktrees "$repo" \
    --mission-dir "$TMP/mission" \
    --control-dir "$TMP/control" \
    --guard-script "$TMP/worker-guard.sh" \
    --gate-script "$TMP/pipeline-gate.sh"
}

mkdir -p "$TMP/mission" "$TMP/control"
printf '#!/usr/bin/env bash\n' > "$TMP/worker-guard.sh"
printf '#!/usr/bin/env bash\n' > "$TMP/pipeline-gate.sh"
chmod +x "$TMP/worker-guard.sh" "$TMP/pipeline-gate.sh"

REPO="$TMP/repo"
new_repo "$REPO"
BEFORE="$(shasum -a 256 "$REPO/.claude/settings.json" | awk '{print $1}')"
run_installer "$REPO" >/dev/null 2>&1
AFTER="$(shasum -a 256 "$REPO/.claude/settings.json" | awk '{print $1}')"
LOCAL="$REPO/.claude/settings.local.json"
STAMP="$TMP/control/worker-settings.sha256"

check "tracked project settings are preserved byte-for-byte" test "$BEFORE" = "$AFTER"
check "local worker settings are installed" test -f "$LOCAL"
check "local settings are valid JSON" bash -c 'jq -e . "$1" >/dev/null' _ "$LOCAL"
check "all template placeholders are rendered" bash -c '! grep -Fq "{{" "$1"' _ "$LOCAL"
check "guard path is rendered" grep -Fq "$TMP/worker-guard.sh" "$LOCAL"
check "gate path is rendered" grep -Fq "$TMP/pipeline-gate.sh" "$LOCAL"
check "local settings are ignored by Git" git -C "$REPO" check-ignore -q .claude/settings.local.json
check "working tree stays clean" bash -c '[[ -z "$(git -C "$1" status --porcelain)" ]]' _ "$REPO"
check "coordinator-owned settings hash is recorded" test -f "$STAMP"
check "settings hash matches the installed file" bash -c '[[ "$(cat "$1")" = "$(shasum -a 256 "$2" | awk '\''{print $1}'\'')" ]]' _ "$STAMP" "$LOCAL"

rm -f "$STAMP"
SOURCE="$TMP/source"
LINKED="$TMP/linked"
new_repo "$SOURCE"
git -C "$SOURCE" worktree add -qb orc/linked "$LINKED"
LINKED_BEFORE="$(shasum -a 256 "$LINKED/.claude/settings.json" | awk '{print $1}')"
run_installer "$LINKED" >/dev/null 2>&1
check "linked worktree preserves shared settings" bash -c '[[ "$1" = "$(shasum -a 256 "$2/.claude/settings.json" | awk '\''{print $1}'\'')" ]]' _ "$LINKED_BEFORE" "$LINKED"
check "linked worktree receives local settings" test -f "$LINKED/.claude/settings.local.json"
check "linked worktree local settings are ignored" git -C "$LINKED" check-ignore -q .claude/settings.local.json
check "linked worktree stays clean" bash -c '[[ -z "$(git -C "$1" status --porcelain)" ]]' _ "$LINKED"

rm -f "$STAMP"
RACE_REPO="$TMP/race-repo"
RACE_BIN="$TMP/race-bin"
new_repo "$RACE_REPO"
mkdir -p "$RACE_BIN"
REAL_JQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nset -eu\n"%s" "$@"\nif [[ ! -e "$ORC_RACE_LOCAL" ]]; then printf "%%s\\n" '\''{"developer":true}'\'' > "$ORC_RACE_LOCAL"; fi\n' "$REAL_JQ" > "$RACE_BIN/jq"
chmod +x "$RACE_BIN/jq"
ORC_RACE_LOCAL="$RACE_REPO/.claude/settings.local.json" PATH="$RACE_BIN:$PATH" \
  check "competing local settings creation fails closed" fails_quietly run_installer "$RACE_REPO"
check "competing local settings are not overwritten" grep -Fq '"developer":true' "$RACE_REPO/.claude/settings.local.json"

PREEXISTING="$TMP/preexisting"
new_repo "$PREEXISTING"
printf '%s\n' '{"permissions":{"allow":["Read"]}}' > "$PREEXISTING/.claude/settings.local.json"
PREEXISTING_HASH="$(shasum -a 256 "$PREEXISTING/.claude/settings.local.json" | awk '{print $1}')"
check "pre-existing local settings fail closed" fails_quietly run_installer "$PREEXISTING"
check "pre-existing local settings are untouched" bash -c '[[ "$1" = "$(shasum -a 256 "$2/.claude/settings.local.json" | awk '\''{print $1}'\'')" ]]' _ "$PREEXISTING_HASH" "$PREEXISTING"

SYMLINKED="$TMP/symlinked"
git init -q "$SYMLINKED"
mkdir -p "$TMP/external-claude"
ln -s "$TMP/external-claude" "$SYMLINKED/.claude"
check "symlinked .claude directory fails closed" fails_quietly run_installer "$SYMLINKED"
check "symlink target is untouched" bash -c '[[ -z "$(find "$1" -mindepth 1 -print -quit)" ]]' _ "$TMP/external-claude"

echo "  install-worker-settings: $OK/$N"
[[ "$OK" -eq "$N" ]]
