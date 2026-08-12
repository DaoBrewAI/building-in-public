#!/usr/bin/env bash
# Tests for scripts/commit-broker.sh — the exec-stage proxy-commit protocol.
set -uo pipefail
BROKER="$(cd "$(dirname "$0")/.." && pwd)/scripts/commit-broker.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MD="$TMP/mission"; WT="$TMP/wt"; CONTROL_DIR="$TMP/control"
mkdir -p "$MD" "$CONTROL_DIR"
git init -q "$WT"
GITC=(git -C "$WT" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
"${GITC[@]}" commit -q --allow-empty -m base
git -C "$WT" checkout -q -b orc/test-mission
printf '%s\t%s\t%s\t%s\n' "$WT" "orc/test-mission" "$(git -C "$WT" rev-parse HEAD)" "$WT" > "$MD/worktrees.txt"
cp "$MD/worktrees.txt" "$CONTROL_DIR/worktrees.txt"
# Broker commits with the repo's config — pin identity/signing for the test repo.
git -C "$WT" config user.email t@t
git -C "$WT" config user.name t
git -C "$WT" config commit.gpgsign false

run_broker() { "$BROKER" --mission-dir "$MD" --control-dir "$CONTROL_DIR" --once >/dev/null 2>&1; }
N=0; OK=0
check() {
  N=$((N + 1))
  if eval "$2"; then OK=$((OK + 1)); else echo "  case $N failed: $1"; fi
}

# 1. valid request -> commit created, DONE carries the hash
echo hello > "$WT/a.txt"
printf '{"worktree":"%s","paths":["a.txt"],"message":"task 1: a"}' "$WT" > "$MD/COMMIT-REQUEST-1.json"
run_broker
H="$(git -C "$WT" rev-parse HEAD)"
check "valid commit" '[[ -f "$MD/COMMIT-DONE-1.json" && "$(jq -r .hash "$MD/COMMIT-DONE-1.json")" == "$H" && "$(git -C "$WT" log -1 --format=%s)" == "task 1: a" ]]'

# 2. unregistered worktree -> REJECTED
mkdir -p "$TMP/evil"
printf '{"worktree":"%s","paths":["x"],"message":"m"}' "$TMP/evil" > "$MD/COMMIT-REQUEST-2.json"
run_broker
check "unregistered worktree" '[[ -f "$MD/COMMIT-REJECTED-2.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-2.json")" == *"not registered"* ]]'

# 3. planted settings file -> REJECTED
mkdir -p "$WT/.claude"; echo '{}' > "$WT/.claude/settings.json"
printf '{"worktree":"%s","paths":[".claude/settings.json"],"message":"m"}' "$WT" > "$MD/COMMIT-REQUEST-3.json"
run_broker
check "settings refused" '[[ -f "$MD/COMMIT-REJECTED-3.json" ]]'
rm -rf "$WT/.claude"

# 4. path escaping the worktree -> REJECTED
printf '{"worktree":"%s","paths":["../escape.txt"],"message":"m"}' "$WT" > "$MD/COMMIT-REQUEST-4.json"
run_broker
check "escape path" '[[ -f "$MD/COMMIT-REJECTED-4.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-4.json")" == *escape* ]]'

# 5. changes outside the request -> REJECTED, nothing committed
echo one > "$WT/b.txt"; echo two > "$WT/c.txt"
printf '{"worktree":"%s","paths":["b.txt"],"message":"only b"}' "$WT" > "$MD/COMMIT-REQUEST-5.json"
BEFORE="$(git -C "$WT" rev-parse HEAD)"
run_broker
check "extra changes rejected" '[[ -f "$MD/COMMIT-REJECTED-5.json" && "$(git -C "$WT" rev-parse HEAD)" == "$BEFORE" ]]'

# 6. split correctly -> both commit
printf '{"worktree":"%s","paths":["b.txt","c.txt"],"message":"b and c"}' "$WT" > "$MD/COMMIT-REQUEST-6.json"
run_broker
check "multi-path commit" '[[ -f "$MD/COMMIT-DONE-6.json" && -z "$(git -C "$WT" status --porcelain)" ]]'

# 7. answered requests are not reprocessed (DONE files stay stable)
D1="$(stat -f %m "$MD/COMMIT-DONE-1.json")"
run_broker
check "idempotent" '[[ "$(stat -f %m "$MD/COMMIT-DONE-1.json")" == "$D1" ]]'

# 8. invalid JSON older than the grace window -> REJECTED
printf 'not json' > "$MD/COMMIT-REQUEST-8.json"
touch -t 202601010000 "$MD/COMMIT-REQUEST-8.json"
run_broker
check "stale invalid json" '[[ -f "$MD/COMMIT-REJECTED-8.json" ]]'

# 9. A worker-controlled manifest rewrite never expands broker authority.
EVIL="$TMP/evil-repo"
git init -q "$EVIL"
git -C "$EVIL" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
echo attack > "$EVIL/attack.txt"
printf '%s\t%s\t%s\t%s\n' "$EVIL" evil "$(git -C "$EVIL" rev-parse HEAD)" "$EVIL" > "$MD/worktrees.txt"
printf '{"worktree":"%s","paths":["attack.txt"],"message":"escape authority"}' "$EVIL" > "$MD/COMMIT-REQUEST-9.json"
EVIL_BEFORE="$(git -C "$EVIL" rev-parse HEAD)"
run_broker
check "mutable worker manifest cannot expand authority" '[[ -f "$MD/COMMIT-REJECTED-9.json" && "$(git -C "$EVIL" rev-parse HEAD)" == "$EVIL_BEFORE" && "$(jq -r .reason "$MD/COMMIT-REJECTED-9.json")" == *"control manifest"* ]]'

# Restore the worker copy for request-level authority checks.
cp "$CONTROL_DIR/worktrees.txt" "$MD/worktrees.txt"

# 10. A suffix of a registered absolute path is not an exact worktree identity.
mkdir -p "$TMP/wt"
printf '{"worktree":"wt","paths":["a.txt"],"message":"relative suffix"}' > "$MD/COMMIT-REQUEST-10.json"
run_broker
check "relative suffix cannot match registered worktree" '[[ -f "$MD/COMMIT-REJECTED-10.json" && "$(jq -r .reason "$MD/COMMIT-REJECTED-10.json")" == *"absolute"* ]]'

# 11. Even the registered path is rejected if it is on another branch.
git -C "$WT" checkout -q -b attacker
echo branch > "$WT/branch.txt"
printf '{"worktree":"%s","paths":["branch.txt"],"message":"wrong branch"}' "$WT" > "$MD/COMMIT-REQUEST-11.json"
BRANCH_BEFORE="$(git -C "$WT" rev-parse HEAD)"
run_broker
check "registered worktree branch is pinned" '[[ -f "$MD/COMMIT-REJECTED-11.json" && "$(git -C "$WT" rev-parse HEAD)" == "$BRANCH_BEFORE" && "$(jq -r .reason "$MD/COMMIT-REJECTED-11.json")" == *"branch"* ]]'

echo "  commit-broker: $OK/$N"
[[ "$OK" -eq "$N" ]]
