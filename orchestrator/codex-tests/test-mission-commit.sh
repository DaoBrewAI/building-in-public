#!/usr/bin/env bash
set -euo pipefail
BROKER="$(cd "$(dirname "$0")/.." && pwd)/codex-scripts/mission-commit.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; WT="$TMP/worktree"; MD="$TMP/mission"; CONTROL="$TMP/control-worktrees.txt"
mkdir -p "$MD"

git init -q "$REPO"
printf '.codex/\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" worktree add -q -b orc/test-mission "$WT"
printf '%s\t%s\t%s\t%s\n' "$WT" "orc/test-mission" "$BASE" "$REPO" > "$MD/worktrees.txt"
cp "$MD/worktrees.txt" "$CONTROL"

printf 'mission output\n' > "$WT/result.txt"
OUT="$("$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL")"; RC=$?
[[ "$RC" -eq 0 && "$OUT" == *"committed"* ]]
[[ "$(git -C "$WT" rev-list --count "$BASE"..orc/test-mission)" -eq 1 ]]
git -C "$WT" show --format= --name-only HEAD | grep -qx result.txt
grep -q '^orc/test-mission' "$MD/commits.txt"

# The broker is idempotent after a successful commit.
"$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL" >/dev/null
[[ "$(git -C "$WT" rev-list --count "$BASE"..orc/test-mission)" -eq 1 ]]

# Rewriting the worker-facing manifest cannot redirect the trusted broker.
EVIL="$TMP/unrelated"; git init -q "$EVIL"
git -C "$EVIL" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
EVIL_BASE="$(git -C "$EVIL" rev-parse HEAD)"
git -C "$EVIL" checkout -q -b orc/evil
printf 'do not commit\n' > "$EVIL/unrelated.txt"
printf '%s\t%s\t%s\t%s\n' "$EVIL" orc/evil "$EVIL_BASE" "$EVIL" > "$MD/worktrees.txt"
if "$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL" >"$TMP/out" 2>"$TMP/err"; then
  echo "broker unexpectedly trusted rewritten worker manifest" >&2
  exit 1
fi
grep -q 'does not match coordinator control manifest' "$TMP/err"
[[ "$(git -C "$EVIL" rev-list --count "$EVIL_BASE"..orc/evil)" -eq 0 ]]
cp "$CONTROL" "$MD/worktrees.txt"

# A hard-linked worker copy is rejected because it would share authority's inode.
rm "$MD/worktrees.txt"
ln "$CONTROL" "$MD/worktrees.txt"
if "$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL" >"$TMP/out" 2>"$TMP/err"; then
  echo "broker unexpectedly accepted hard-linked manifest" >&2
  exit 1
fi
grep -q 'hard link' "$TMP/err"
rm "$MD/worktrees.txt"
cp "$CONTROL" "$MD/worktrees.txt"

# Policy/memory changes are rejected instead of being committed.
printf 'policy mutation\n' > "$WT/AGENTS.md"
if "$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL" >"$TMP/out" 2>"$TMP/err"; then
  echo "broker unexpectedly accepted AGENTS.md" >&2
  exit 1
fi
grep -q 'protected path' "$TMP/err"
[[ "$(git -C "$WT" rev-list --count "$BASE"..orc/test-mission)" -eq 1 ]]

# Ignored policy files are still detected.
rm "$WT/AGENTS.md"
mkdir -p "$WT/.codex"
printf '{}\n' > "$WT/.codex/hooks.json"
if "$BROKER" --mission-dir "$MD" --control-manifest "$CONTROL" >"$TMP/out" 2>"$TMP/err"; then
  echo "broker unexpectedly accepted ignored .codex/hooks.json" >&2
  exit 1
fi
grep -q 'protected path' "$TMP/err"
[[ "$(git -C "$WT" rev-list --count "$BASE"..orc/test-mission)" -eq 1 ]]

echo "  mission-commit: linked-worktree commit + policy rejection passed"
