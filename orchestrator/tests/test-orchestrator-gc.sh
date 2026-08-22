#!/usr/bin/env bash
# Regression tests for completed-mission branch/worktree garbage collection.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GC="$ROOT/scripts/orchestrator-gc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "  $1" >&2
  exit 1
}

new_mission() {
  local root="$1" slug="$2" state="$3" worktree="$4" branch="$5" repo="$6"
  mkdir -p "$root/$slug"
  printf '%s\n' "$state" > "$root/$slug/state"
  printf '%s\t%s\tmain\t%s\n' "$worktree" "$branch" "$repo" > "$root/$slug/worktrees.txt"
}

HUB="$TMP/.orchestrator"
REPO="$TMP/repo"
REMOTE="$TMP/remote.git"
mkdir -p "$HUB/archive" "$HUB/missions" "$HUB/control"
git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" remote add origin "$REMOTE"
printf '%s\n' base > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm base
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

DONE_SLUG="done-mission"
DONE_BRANCH="orc/$DONE_SLUG"
DONE_WT="$TMP/.worktrees/$DONE_SLUG/repo"
mkdir -p "$(dirname "$DONE_WT")"
git -C "$REPO" worktree add -qb "$DONE_BRANCH" "$DONE_WT" main >/dev/null
git -C "$REPO" push -q -u origin "$DONE_BRANCH"
new_mission "$HUB/archive" "$DONE_SLUG" accepted "$DONE_WT" "$DONE_BRANCH" "$REPO"

ACTIVE_SLUG="active-mission"
ACTIVE_BRANCH="orc/$ACTIVE_SLUG"
ACTIVE_WT="$TMP/.worktrees/$ACTIVE_SLUG/repo"
mkdir -p "$(dirname "$ACTIVE_WT")"
git -C "$REPO" worktree add -qb "$ACTIVE_BRANCH" "$ACTIVE_WT" main >/dev/null
git -C "$REPO" push -q -u origin "$ACTIVE_BRANCH"
new_mission "$HUB/missions" "$ACTIVE_SLUG" running "$ACTIVE_WT" "$ACTIVE_BRANCH" "$REPO"

UNARCHIVED_SLUG="accepted-unarchived"
UNARCHIVED_BRANCH="orc/$UNARCHIVED_SLUG"
UNARCHIVED_WT="$TMP/.worktrees/$UNARCHIVED_SLUG/repo"
mkdir -p "$(dirname "$UNARCHIVED_WT")"
git -C "$REPO" worktree add -qb "$UNARCHIVED_BRANCH" "$UNARCHIVED_WT" main >/dev/null
git -C "$REPO" push -q -u origin "$UNARCHIVED_BRANCH"
new_mission "$HUB/missions" "$UNARCHIVED_SLUG" accepted "$UNARCHIVED_WT" "$UNARCHIVED_BRANCH" "$REPO"

# A completed manifest may have been created on another device. It cannot be
# cleaned here, but must not block cleanup for repositories that are present.
new_mission "$HUB/archive" "foreign-device" accepted \
  "/missing/worktree" "orc/foreign-device" "/missing/repository"

# Integrated child resources are coordinator-authoritative under control/, not
# mission-local manifests. Exercise exact child cleanup beside legacy parent GC.
CHILD_MISSION="child-parent"
CHILD_ID="task-a"
CHILD_BRANCH="orc-task/$CHILD_MISSION/$CHILD_ID"
CHILD_PARENT="$TMP/child-parent"
CHILD_WT="$TMP/child-worktree"
CHILD_CONTROL="$HUB/control/$CHILD_MISSION/tasks/$CHILD_ID"
git -C "$REPO" worktree add -qb "orc/$CHILD_MISSION" "$CHILD_PARENT" main >/dev/null
CHILD_BASE="$(git -C "$CHILD_PARENT" rev-parse HEAD)"
git -C "$REPO" worktree add -qb "$CHILD_BRANCH" "$CHILD_WT" "$CHILD_BASE" >/dev/null
printf '%s\n' child > "$CHILD_WT/child.txt"
git -C "$CHILD_WT" add child.txt
git -C "$CHILD_WT" commit -qm child
CHILD_TIP="$(git -C "$CHILD_WT" rev-parse HEAD)"
git -C "$CHILD_WT" push -q -u origin "$CHILD_BRANCH"
git -C "$CHILD_PARENT" merge -q --no-ff --no-edit "$CHILD_BRANCH"
CHILD_INTEGRATED="$(git -C "$CHILD_PARENT" rev-parse HEAD)"
CHILD_WT="$(cd "$CHILD_WT" && pwd -P)"
CHILD_PARENT="$(cd "$CHILD_PARENT" && pwd -P)"
CHILD_REPO="$(cd "$REPO" && pwd -P)"
mkdir -p "$CHILD_CONTROL"
printf '%s\t%s\t%s\t%s\n' "$CHILD_WT" "$CHILD_BRANCH" "$CHILD_BASE" "$CHILD_REPO" > "$CHILD_CONTROL/worktrees.txt"
printf '%s\n' integrated > "$CHILD_CONTROL/state"
printf '1\n' > "$CHILD_CONTROL/generation"
printf '%s\n' "$CHILD_INTEGRATED" > "$CHILD_CONTROL/integrated_sha"
printf '%s\n' "$CHILD_PARENT" > "$CHILD_CONTROL/parent-worktree"
printf '%s\n' "$CHILD_TIP" > "$CHILD_CONTROL/child_tip"

BLOCKED_ID="task-blocked"
BLOCKED_BRANCH="orc-task/$CHILD_MISSION/$BLOCKED_ID"
BLOCKED_WT="$TMP/blocked-child-worktree"
BLOCKED_CONTROL="$HUB/control/$CHILD_MISSION/tasks/$BLOCKED_ID"
git -C "$REPO" worktree add -qb "$BLOCKED_BRANCH" "$BLOCKED_WT" "$CHILD_INTEGRATED" >/dev/null
mkdir -p "$BLOCKED_CONTROL"
printf '%s\t%s\t%s\t%s\n' "$BLOCKED_WT" "$BLOCKED_BRANCH" "$CHILD_INTEGRATED" "$REPO" > "$BLOCKED_CONTROL/worktrees.txt"
printf '%s\n' blocked > "$BLOCKED_CONTROL/state"

REPORT="$($GC --hub "$HUB")" || fail "foreign-device manifests must not make report-only GC fail"
grep -Fq "stale remote branch ($DONE_SLUG): $DONE_BRANCH" <<<"$REPORT" \
  || fail "report must include the completed mission's remote branch"
grep -Fq "stale remote branch ($UNARCHIVED_SLUG): $UNARCHIVED_BRANCH" <<<"$REPORT" \
  || fail "accepted missions must be collectible even before archival"
grep -Fq "$CHILD_BRANCH" <<<"$REPORT" \
  || fail "report must include the exact integrated child branch"
if grep -Fq "$ACTIVE_BRANCH" <<<"$REPORT"; then
  fail "running mission appeared in the GC report"
fi
if grep -Fq "$BLOCKED_BRANCH" <<<"$REPORT"; then
  fail "blocked child appeared in the GC report"
fi

$GC --hub "$HUB" --clean >/dev/null

[[ ! -e "$DONE_WT" ]] || fail "completed worktree was not removed"
[[ ! -e "$UNARCHIVED_WT" ]] || fail "accepted unarchived worktree was not removed"
! git -C "$REPO" show-ref --verify --quiet "refs/heads/$DONE_BRANCH" \
  || fail "completed local branch was not removed"
! git -C "$REPO" show-ref --verify --quiet "refs/heads/$UNARCHIVED_BRANCH" \
  || fail "accepted unarchived local branch was not removed"
! git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$DONE_BRANCH" \
  || fail "completed remote branch was not removed"
! git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$UNARCHIVED_BRANCH" \
  || fail "accepted unarchived remote branch was not removed"

[[ ! -e "$CHILD_WT" ]] || fail "integrated child worktree was not removed"
! git -C "$REPO" show-ref --verify --quiet "refs/heads/$CHILD_BRANCH" \
  || fail "integrated child local branch was not removed"
! git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$CHILD_BRANCH" \
  || fail "integrated child remote branch was not removed"
[[ "$(cat "$CHILD_CONTROL/state")" == collected ]] \
  || fail "integrated child state was not advanced to collected"

[[ -d "$ACTIVE_WT" ]] || fail "running worktree was removed"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$ACTIVE_BRANCH" \
  || fail "running local branch was removed"
git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$ACTIVE_BRANCH" \
  || fail "running remote branch was removed"
[[ -d "$BLOCKED_WT" ]] || fail "blocked child worktree was removed"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BLOCKED_BRANCH" \
  || fail "blocked child local branch was removed"

echo "  orchestrator-gc: completed parent and integrated child resources removed; unsafe resources preserved"
