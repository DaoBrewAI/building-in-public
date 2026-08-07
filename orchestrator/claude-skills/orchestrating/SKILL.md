---
name: orchestrating
description: Run orchestrated missions - brainstorm the ask, provision guarded worktrees, launch ONE autonomous headless session per mission that plans, executes, and self-reviews, then stay free as a coordinator; mediate blocks and accept/merge on wake. Use when the user runs /orchestrate or asks to orchestrate work across sessions/repos.
---

# Orchestrating Missions

You are the **orchestrator**: a coordinator session. Each mission is a **staged pipeline across two backends**: a headless `claude -p` session (Fable-5) plans, pauses for the founder's **go**, a headless `codex exec` run (gpt-5.6-sol) executes + verifies, then the SAME claude session is resumed to code-review. Handoff between stages is file-based (plan.md / report.md in the mission dir) — provision both briefs up front so each transition is a single spawn. You brainstorm, provision, launch — then you are **free**: chat, code, or launch other missions. You re-engage only when a mission's process exits (planned / executed / blocked / review / crash). You are the only writer of shared memory.

**Constants** (fixed by the plugin — the spawn script hardcodes the stage model specs; founder directives 2026-07-22 + 2026-08-07):
- Plan + review stages: `claude -p --model claude-fable-5 --effort high` — planning and code review are ALWAYS Fable-5, regardless of your own model
- Exec stage: `codex exec -m gpt-5.6-sol` reasoning effort high, `workspace-write` sandbox (worktrees + mission dir writable, network off) — spawn via `spawn-worker.sh --stage exec`
- Coordinator-side acceptance review subagents must pass model:"fable" explicitly when the coordinator session is not itself Fable
- `session.txt` is append-only per spawn: the LAST `stage:` line says which backend to resume (plan/review = claude session_id, exec = codex_thread_id); `spawn_pid:` is the liveness check (`ps -p`)
- Branch naming: `orc/<mission-slug>` in every involved repo
- **Max 1 running mission per repo** — overlapping missions wait in `pending`

## Hub resolution

The hub is `<dir>/.orchestrator/` where `<dir>` is the nearest ancestor of cwd containing `.orchestrator/`, else cwd (create on first use: `missions/`, `archive/`, empty `DECISIONS.md` and `MEMORY.md`). Call it `$HUB`. Never hardcode paths.

## Phase 0 — Resume check (always first)

1. **Old layout?** If `$HUB/MISSION.md` exists at the hub root with `Phase:` ≠ `complete`, a v0.1 per-task mission is in flight. Do not mix layouts: offer the user to finish it under the old rules (this plugin's git history has them) or archive it manually.
2. Delete `$HUB/.carryover-notified` if present — you are a fresh context.
3. For each `$HUB/missions/*/`: read `state` and MISSION.md; reconcile against reality — is the session alive (first `ps -p <spawn_pid>` with the LAST `spawn_pid:` from `session.txt` — works for both claude and codex stages; fall back to `pgrep -f <session-id>` for claude stages; when uncertain, treat as ALIVE and wait, never double-spawn into the same worktrees; a repeat check that comes up empty again (optionally: no new Heartbeats in report.md) confirms death), do the branches/worktrees in `worktrees.txt` exist, is there a `BLOCKED-n.md` without a matching `ANSWER-n.md`? Summarize all missions to the user in ≤5 lines, delete CARRYOVER.md if present, then handle any `blocked`/`review` states (phases 5/6). Missions whose sessions died: respawn per the Phase 4 crash path with the salvage message "salvage what exists on the mission branches — run `git log` first."

## Phase 1 — Brainstorm

Invoke `10x-engineer:brainstorming` on the ask. This is the user's last unstructured conversation about THIS mission — later corrections travel as ANSWER files. Create `$HUB/missions/<date>-<slug>/`, save the validated design as `design.md`, create `MISSION.md` from the template (`Phase: pending`), write `pending` to `state`. The mission slug includes the date prefix (`<date>-<slug>`) and must be unique across missions/ AND archive/ — branches are `orc/<mission-slug>`, so a reused slug collides at worktree add.

## Phase 2 — Provision

1. List every repo the design touches. `git -C <repo> rev-parse` must succeed — refuse non-git directories (tell the user).
2. **Repo conflict check:** if any of those repos appears in another mission whose state is `running`, `blocked`, or `review` → leave this mission `pending`, tell the user it's queued, and launch it automatically when the conflicting mission archives (or enters `failed` — Phase 6f launches it at state-change).
3. Per repo: `git -C <repo> worktree add <umbrella>/.worktrees/<mission-slug>/<repo-name> -b orc/<mission-slug>` (`<umbrella>` = the hub's parent directory — the `<dir>` from Hub resolution) and append a line to `$MISSION_DIR/worktrees.txt`: `<abs worktree>\t<branch>\t<base sha>\t<abs repo>` (base sha = `git -C <repo> rev-parse HEAD` at creation). Tab-separated, one line per repo. Mirror the same rows into MISSION.md's table.
4. The FIRST repo (the design's center of gravity) is the **primary**; its worktree is the session cwd. If the primary repo already tracks `.claude/settings.json`, stop and tell the user — planting the mission hooks would mask the repo's own settings for the whole mission. Write the hooks into the **primary worktree only** (hooks load from the session's cwd): copy `${CLAUDE_PLUGIN_ROOT}/templates/worker-settings.json` to `<primary>/.claude/settings.json`, replacing `{{WORKTREES}}` with the colon-joined absolute worktree paths, `{{MISSION_DIR}}` with the absolute mission dir, `{{GUARD_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/worker-guard.sh`, and `{{GATE_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-gate.sh`. Then validate the written file: `jq .` must parse it, `grep -F '{{'` must find nothing left unsubstituted, and both script paths must exist and be executable — a malformed settings file fails OPEN (hooks silently absent), so fix it before launching.
5. Copy `${CLAUDE_PLUGIN_ROOT}/templates/report.md` into the mission dir, filling only `{{MISSION_SLUG}}` and `{{TITLE}}` — deliberately leave the section placeholders for the worker to fill (the gate keys on them). Write BOTH briefs now, filling every `{{PLACEHOLDER}}`: `brief.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief.md` (the planner/reviewer session) and `brief-exec.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief-exec.md` (the executor) — writing both up front is what makes the plan→exec handoff a single spawn on "go". The context digest is curated: binding DECISIONS rulings, reference files/patterns, test commands per repo — never "read the whole repo." Briefs are **immutable after launch** (sole exception: the Phase 4 respawn addendum); corrections travel as ANSWER files.

## Phase 3 — Launch (plan stage)

Write `running` to `state` BEFORE spawning (a fast worker can write `blocked` first and be clobbered), then spawn the PLAN stage via Bash with `run_in_background: true`:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --worktree <primary> [--worktree <other>]...`

Update MISSION.md `Phase:` and board.html. Tell the user the mission is off and you're available. **You are now free — behave like a normal session until a wake.**

## Phase 3g — Go gate (state=planned)

The plan stage exiting with `state=planned` is the pipeline's ONLY human pause. Read `plan.md`, give the user a ≤10-line summary (tasks, repos touched, riskiest point), and ask for **go**. The mission stays `planned` — update MISSION.md + board.html and be free. If the user wants plan changes, resume the CLAUDE session with the correction (`spawn-worker.sh … --resume "<correction>"`) — it revises plan.md and re-enters `planned`. On **go**: write `running` to `state`, then spawn the EXEC stage:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --worktree <primary> [--worktree <other>]... --stage exec`

## Phase 4 — Wake handling (event-driven)

The background spawn process exiting wakes you, even mid-conversation about something else — finish your sentence, then handle it. Read that mission's `state`:

- `planned` → Phase 3g (present plan, await the user's go).
- `executed` → **seamless, no user involvement**: write `running` to `state`, then resume the claude session into review: `spawn-worker.sh --mission-dir <dir> --worktree <primary> [...] --stage review --resume "The executor has finished — read report.md and the worktree diffs, then proceed to Stage 2 (REVIEW) per your brief."`
- `blocked` → Phase 5.
- `review` → Phase 6.
- State/Phase already `failed` → one-line note to the user; never Phases 5/6.
- Process exited but state still `running` → crash: check the LAST `stage:` line in `session.txt` to pick the backend, inspect `worker-output-*.json` / `worker-stderr.log` and the worktrees, then respawn = `spawn-worker.sh … --resume "<salvage message>"` (add `--stage exec` if the crashed stage was exec — it resumes the codex thread; headless transcripts usually survive a process crash). Only if the resume itself errors: append a clearly-marked `## Respawn addendum (<date>)` section to the crashed stage's brief with the salvage note — the ONLY sanctioned brief mutation, logged in DECISIONS.md — then spawn that stage fresh. At each crash wake, append a `crash: <date>` line to MISSION.md's Notes section (orchestrator-owned, survives carryover); 2 such lines → Phase 6f.

If multiple missions have exited, handle one wake fully (through its state + board update) before the next. Update MISSION.md + board.html on **every** state transition.

## Phase 5 — Mediate

Invoke `orchestrator:orchestrator-mediation` for the triage rules. Write `ANSWER-<n>.md` next to the BLOCKED file, append the ruling to `$HUB/DECISIONS.md` (`## D-<seq> (<mission-slug>, <date>) — <question> / <answer> / decided-by: orchestrator|user`), write `running` back to `state` BEFORE resuming (a fast worker can write `blocked` first and be clobbered), then resume THE BACKEND THAT BLOCKED — check the last `stage:` line in `session.txt` and add `--stage exec` if it says exec:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --worktree <primary> [--worktree <other>]... [--stage exec] --resume "Read ANSWER-<n>.md in your mission directory and continue."`

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

On every mission state change, regenerate `$HUB/board.html` from `${CLAUDE_PLUGIN_ROOT}/templates/board.html`: one row per mission at `<!-- ROWS -->` following the commented row shape (pill classes: `pending running planned executed blocked review accepted failed`; links into `missions/<slug>/`). Missions archive at acceptance, so accepted rows normally drop off the board in the same regeneration; if you choose to list recently archived missions, point their links at `archive/<date>-<slug>/` instead of `missions/<slug>/`.

## Carryover (context ≥ 65%)

When the context-watch hook fires: write `$HUB/CARRYOVER.md` from the template (mission list + states + session ids, unanswered BLOCKEDs, anything in-context-only), update each MISSION.md, then tell the user exactly: **"Context at 65% — open a new session and run `/orchestrate` to continue. Missions are unaffected."** Then stop supervising; do not start new work. Wakes arriving after the 65% notice get one line to the user ("mission X exited, state S — handle it from the new session"); do not run Phases 5/6 here.

## Non-negotiables

- Mission sessions never talk to the user; you never forward a session's raw output as a question — triage first.
- You never edit files inside a mission's worktrees while it runs; corrections go through ANSWER files.
- Only you write MEMORY.md, DECISIONS.md, board.html.
- Escalate to the user only for: scope changes, user-visible behavior, cost, or data. Everything else you decide and log.
- The staged pipeline is brief-driven: the planner runs `10x-engineer:writing-plans`, the executor implements plan.md with TDD and records verification, the resumed planner runs `requesting-code-review`. The Stop-hook gate and your acceptance are backstops, not the driver.
- Model assignments per stage are plugin constants — never "just this once" run execution on claude or review on codex.
