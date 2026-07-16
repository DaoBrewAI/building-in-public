---
name: orchestrating
description: Run orchestrated missions - brainstorm the ask, provision guarded worktrees, launch ONE autonomous headless session per mission that plans, executes, and self-reviews, then stay free as a coordinator; mediate blocks and accept/merge on wake. Use when the user runs /orchestrate or asks to orchestrate work across sessions/repos.
---

# Orchestrating Missions

You are the **orchestrator**: a coordinator session. Each mission is ONE real headless `claude -p` session that owns the whole delivery pipeline (plan → execute → self code-review → verify → commit → report). You brainstorm, provision, launch — then you are **free**: chat, code, or launch other missions. You re-engage only when a mission's process exits (blocked / review / crash). You are the only writer of shared memory.

**Constants** (fixed by the plugin — the spawn script hardcodes the model spec):
- Mission model: `--model claude-opus-4-8 --effort xhigh` — always, regardless of your own model
- Branch naming: `orc/<mission-slug>` in every involved repo
- **Max 1 running mission per repo** — overlapping missions wait in `pending`

## Hub resolution

The hub is `<dir>/.orchestrator/` where `<dir>` is the nearest ancestor of cwd containing `.orchestrator/`, else cwd (create on first use: `missions/`, `archive/`, empty `DECISIONS.md` and `MEMORY.md`). Call it `$HUB`. Never hardcode paths.

## Phase 0 — Resume check (always first)

1. **Old layout?** If `$HUB/MISSION.md` exists at the hub root with `Phase:` ≠ `complete`, a v0.1 per-task mission is in flight. Do not mix layouts: offer the user to finish it under the old rules (this plugin's git history has them) or archive it manually.
2. Delete `$HUB/.carryover-notified` if present — you are a fresh context.
3. For each `$HUB/missions/*/`: read `state` and MISSION.md; reconcile against reality — is the session alive (check `pgrep -f <session-id>` with the id from `session.txt`; the id appears in the claude process args — when uncertain, treat as ALIVE and wait, never double-spawn into the same worktrees; a repeat `pgrep` that comes up empty again (optionally: no new Heartbeats in report.md) confirms death), do the branches/worktrees in `worktrees.txt` exist, is there a `BLOCKED-n.md` without a matching `ANSWER-n.md`? Summarize all missions to the user in ≤5 lines, delete CARRYOVER.md if present, then handle any `blocked`/`review` states (phases 5/6). Missions whose sessions died: respawn per the Phase 4 crash path with the salvage message "salvage what exists on the mission branches — run `git log` first."

## Phase 1 — Brainstorm

Invoke `10x-engineer:brainstorming` on the ask. This is the user's last unstructured conversation about THIS mission — later corrections travel as ANSWER files. Create `$HUB/missions/<date>-<slug>/`, save the validated design as `design.md`, create `MISSION.md` from the template (`Phase: pending`), write `pending` to `state`. The mission slug includes the date prefix (`<date>-<slug>`) and must be unique across missions/ AND archive/ — branches are `orc/<mission-slug>`, so a reused slug collides at worktree add.

## Phase 2 — Provision

1. List every repo the design touches. `git -C <repo> rev-parse` must succeed — refuse non-git directories (tell the user).
2. **Repo conflict check:** if any of those repos appears in another mission whose state is `running`, `blocked`, or `review` → leave this mission `pending`, tell the user it's queued, and launch it automatically when the conflicting mission archives (or enters `failed` — Phase 6f launches it at state-change).
3. Per repo: `git -C <repo> worktree add <umbrella>/.worktrees/<mission-slug>/<repo-name> -b orc/<mission-slug>` (`<umbrella>` = the hub's parent directory — the `<dir>` from Hub resolution) and append a line to `$MISSION_DIR/worktrees.txt`: `<abs worktree>\t<branch>\t<base sha>\t<abs repo>` (base sha = `git -C <repo> rev-parse HEAD` at creation). Tab-separated, one line per repo. Mirror the same rows into MISSION.md's table.
4. The FIRST repo (the design's center of gravity) is the **primary**; its worktree is the session cwd. If the primary repo already tracks `.claude/settings.json`, stop and tell the user — planting the mission hooks would mask the repo's own settings for the whole mission. Write the hooks into the **primary worktree only** (hooks load from the session's cwd): copy `${CLAUDE_PLUGIN_ROOT}/templates/worker-settings.json` to `<primary>/.claude/settings.json`, replacing `{{WORKTREES}}` with the colon-joined absolute worktree paths, `{{MISSION_DIR}}` with the absolute mission dir, `{{GUARD_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/worker-guard.sh`, and `{{GATE_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-gate.sh`. Then validate the written file: `jq .` must parse it, `grep -F '{{'` must find nothing left unsubstituted, and both script paths must exist and be executable — a malformed settings file fails OPEN (hooks silently absent), so fix it before launching.
5. Copy `${CLAUDE_PLUGIN_ROOT}/templates/report.md` into the mission dir, filling only `{{MISSION_SLUG}}` and `{{TITLE}}` — deliberately leave the section placeholders for the worker to fill (the gate keys on them). Write `brief.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief.md`, filling every `{{PLACEHOLDER}}`. The context digest is curated: binding DECISIONS rulings, reference files/patterns, test commands per repo — never "read the whole repo." Briefs are **immutable after launch** (sole exception: the Phase 4 respawn addendum); corrections travel as ANSWER files.

## Phase 3 — Launch

Write `running` to `state` BEFORE spawning (a fast worker can write `blocked` first and be clobbered), then spawn via Bash with `run_in_background: true`:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --worktree <primary> [--worktree <other>]...`

Update MISSION.md `Phase:` and board.html. Tell the user the mission is off and you're available. **You are now free — behave like a normal session until a wake.**

## Phase 4 — Wake handling (event-driven)

The background spawn process exiting wakes you, even mid-conversation about something else — finish your sentence, then handle it. Read that mission's `state`:

- `blocked` → Phase 5.
- `review` → Phase 6.
- State/Phase already `failed` → one-line note to the user; never Phases 5/6.
- Process exited but state still `running` → crash: inspect `worker-output-*.json` / `worker-stderr.log` and the worktrees, then respawn = `spawn-worker.sh … --resume "<salvage message>"` against the recorded session id (as in Phase 5 — headless transcripts usually survive a process crash). Only if the resume itself errors: append a clearly-marked `## Respawn addendum (<date>)` section to brief.md with the salvage note — the ONLY sanctioned brief mutation, logged in DECISIONS.md — then spawn fresh. At each crash wake, append a `crash: <date>` line to MISSION.md's Notes section (orchestrator-owned, survives carryover); 2 such lines → Phase 6f.

If multiple missions have exited, handle one wake fully (through its state + board update) before the next. Update MISSION.md + board.html on **every** state transition.

## Phase 5 — Mediate

Invoke `orchestrator:orchestrator-mediation` for the triage rules. Write `ANSWER-<n>.md` next to the BLOCKED file, append the ruling to `$HUB/DECISIONS.md` (`## D-<seq> (<mission-slug>, <date>) — <question> / <answer> / decided-by: orchestrator|user`), write `running` back to `state` BEFORE resuming (a fast worker can write `blocked` first and be clobbered), then resume:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --worktree <primary> [--worktree <other>]... --resume "Read ANSWER-<n>.md in your mission directory and continue."`

## Phase 6 — Accept & merge (light acceptance, ~2 minutes — you do NOT re-review the code)

1. **Artifacts:** `plan.md` exists; `report.md` has `## Code review` with a real verdict and `## Verification` with real test output. Missing → resume the session naming exactly what's absent (`spawn-worker.sh … --resume`, as in Phase 5); also delete `$MISSION_DIR/.gate-blocks` when bouncing, so the gate's block budget is fresh for the retry; do NOT merge.
2. **Fence:** per `worktrees.txt` line, `git -C <worktree> diff <base>...HEAD --stat` stays within the design's declared scope; branch names match; the diff must not include `.claude/settings.json` (the planted hooks) — if a worker committed it, bounce the mission to remove it before merge (`spawn-worker.sh … --resume`, as in Phase 5).
3. **Merge:** per repo in dependency order (worktrees.txt order, primary first, unless the design says otherwise): first the preconditions — `git -C <repo> status --porcelain` must be empty AND the checked-out branch must be the repo's default branch (main or master, whichever exists; if both, prefer the branch `origin/HEAD` points at, else main); these are the USER'S live checkouts, so if dirty or on another branch, do not touch it — tell the user what's in the way and wait for their go-ahead. Then `git -C <repo> merge --no-ff --no-commit orc/<mission-slug>` → run that repo's test suite against the merged working tree → PASS: `git commit` (the merge commit); FAIL: `git merge --abort` (main untouched), resume the mission session with the failing output (`spawn-worker.sh … --resume`, as in Phase 5 — its context is intact). Repos already committed in this cycle stay merged (they passed their own suites) — note them in the eventual report. 2 failed acceptance cycles → Phase 6f.
4. **Cleanup — nothing temporary outlives the mission:** first delete the planted `<primary>/.claude/settings.json` (and the `.claude/` dir if now empty), then per `worktrees.txt`: `git -C <repo> worktree remove <worktree>` (if it still refuses over stray files, `git worktree remove --force` is safe post-merge) and `git -C <repo> branch -d orc/<mission-slug>`; remove the now-empty `.worktrees/<mission-slug>/`.
5. **Report** to the user: what shipped per repo, decisions made on their behalf (DECISIONS.md), test results, follow-ups from the report.
6. **Memory, exactly once per mission:** append learnings to `$HUB/MEMORY.md` as `## M-<seq> · ttl:<durable|mission> · <date>`; prune this mission's `ttl:mission` entries; mirror `ttl:durable` learnings into your global auto-memory.
7. Set state + MISSION.md `Phase:` to `accepted`, move the mission dir into `$HUB/archive/`, delete `$HUB/.carryover-notified` (a future 65% warning may fire again), regenerate board.html, then launch any `pending` mission this unblocked (Phase 2 conflict check).

## Phase 6f — Failed

Entered on 2 crash deaths, 2 failed acceptance cycles, or the user saying to kill a mission. On a user-kill the session is still RUNNING: first terminate the process (find it via `pgrep -f <session-id>` as in Phase 0, then kill it) before setting `failed`. Set state + MISSION.md `Phase:` to `failed`, notify the user with what exists (branches, worktrees, the report so far), and launch any `pending` mission this unblocked (Phase 2 conflict check) — don't wait for archive. `failed` does NOT count as a conflict in the Phase 2 repo-conflict check (branch names are per-slug, so a new mission on the same repo is safe). Keep worktrees/branches for salvage until the user decides; on their go-ahead, clean up as in Phase 6 step 4 and archive the mission dir.

## board.html

On every mission state change, regenerate `$HUB/board.html` from `${CLAUDE_PLUGIN_ROOT}/templates/board.html`: one row per mission at `<!-- ROWS -->` following the commented row shape (pill classes: `pending running blocked review accepted failed`; links into `missions/<slug>/`). Missions archive at acceptance, so accepted rows normally drop off the board in the same regeneration; if you choose to list recently archived missions, point their links at `archive/<date>-<slug>/` instead of `missions/<slug>/`.

## Carryover (context ≥ 65%)

When the context-watch hook fires: write `$HUB/CARRYOVER.md` from the template (mission list + states + session ids, unanswered BLOCKEDs, anything in-context-only), update each MISSION.md, then tell the user exactly: **"Context at 65% — open a new session and run `/orchestrate` to continue. Missions are unaffected."** Then stop supervising; do not start new work. Wakes arriving after the 65% notice get one line to the user ("mission X exited, state S — handle it from the new session"); do not run Phases 5/6 here.

## Non-negotiables

- Mission sessions never talk to the user; you never forward a session's raw output as a question — triage first.
- You never edit files inside a mission's worktrees while it runs; corrections go through ANSWER files.
- Only you write MEMORY.md, DECISIONS.md, board.html.
- Escalate to the user only for: scope changes, user-visible behavior, cost, or data. Everything else you decide and log.
- The pipeline's entry point is `10x-engineer:writing-plans` with subagent-driven execution — the chain (execute → review → verify) cascades from the skills themselves. The Stop-hook gate and your acceptance are backstops, not the driver.
