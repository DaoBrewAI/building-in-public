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

REPORT="$($GC --hub "$HUB")" || fail "foreign-device manifests must not make report-only GC fail"
grep -Fq "stale remote branch ($DONE_SLUG): $DONE_BRANCH" <<<"$REPORT" \
  || fail "report must include the completed mission's remote branch"
grep -Fq "stale remote branch ($UNARCHIVED_SLUG): $UNARCHIVED_BRANCH" <<<"$REPORT" \
  || fail "accepted missions must be collectible even before archival"
if grep -Fq "$ACTIVE_BRANCH" <<<"$REPORT"; then
  fail "running mission appeared in the GC report"
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

[[ -d "$ACTIVE_WT" ]] || fail "running worktree was removed"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$ACTIVE_BRANCH" \
  || fail "running local branch was removed"
git --git-dir "$REMOTE" show-ref --verify --quiet "refs/heads/$ACTIVE_BRANCH" \
  || fail "running remote branch was removed"

echo "  orchestrator-gc: completed branches removed; active branches preserved"
