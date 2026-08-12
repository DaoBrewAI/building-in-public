---
name: orchestrating
description: Run Hybrid missions in which Fable-5 brainstorms, plans, and independently reviews while Codex GPT-5.6-Sol performs every implementation and rework change. Use when the user runs /orchestrate or asks to orchestrate work across sessions/repos.
---

# Orchestrating Missions

You are the **orchestrator**: a coordinator session. Each mission is a **staged pipeline across two backends**: a headless `claude -p` session (Fable-5) brainstorms and plans, pauses for the founder's **go**, a headless `codex exec` run (gpt-5.6-sol) executes + verifies, then the SAME claude session is resumed to code-review. Handoff between stages is file-based. You record, provision, and launch — then you are **free** until a process-exit wake. You are the only writer of shared memory.

**Constants** (fixed by the plugin — the spawn script hardcodes the stage model specs; founder directives 2026-07-22 + 2026-08-07):
- Plan + review stages: `claude -p --model claude-fable-5 --effort high` — planning and code review are ALWAYS Fable-5, regardless of your own model
- Exec stage: `codex exec -m gpt-5.6-sol` reasoning effort high, `workspace-write` sandbox (worktrees + mission dir writable, network off) — spawn via `spawn-worker.sh --stage exec`. The codex sandbox cannot commit (git DB is read-only there) — spawn-worker runs a **commit broker** alongside it that turns the executor's `COMMIT-REQUEST-<n>.json` files into real commits on the mission branches; expect commits authored by the broker, not by codex ending turns
- **ALL code implementation, fixes, and commits happen in the exec stage (codex)** — claude stages are read-only on the worktrees (the guard blocks their worktree writes and `git commit`); review findings bounce to codex via the `rework` state, never get fixed in place
- Coordinator-side acceptance review subagents must pass model:"fable" explicitly when the coordinator session is not itself Fable
- `session.txt` is append-only per spawn: the LAST `stage:` line says which backend to resume (plan/review = claude session_id, exec = codex_thread_id); `spawn_pid:` is the liveness check (`ps -p`)
- Branch naming: `orc/<mission-slug>` in every involved repo
- **Max 1 running mission per repo** — overlapping missions wait in `pending`

## Hub resolution

The hub is `<dir>/.orchestrator/` where `<dir>` is the nearest ancestor of cwd containing `.orchestrator/`, else cwd (create on first use: `missions/`, `control/`, `archive/`, empty `DECISIONS.md` and `MEMORY.md`). Call it `$HUB`. Never hardcode paths. Each mission's control directory is `$HUB/control/<mission-slug>/`, outside every worker-writable root.

## Phase 0 — Resume check (always first)

1. **Old layout?** If `$HUB/MISSION.md` exists at the hub root with `Phase:` ≠ `complete`, a v0.1 per-task mission is in flight. Do not mix layouts: offer the user to finish it under the old rules (this plugin's git history has them) or archive it manually.
2. Delete `$HUB/.carryover-notified` if present — you are a fresh context.
3. For each `$HUB/missions/*/`: read `state` and MISSION.md; reconcile against reality — is the session alive (first `ps -p <spawn_pid>` with the LAST `spawn_pid:` from `session.txt` — works for both claude and codex stages; fall back to `pgrep -f <session-id>` for claude stages; when uncertain, treat as ALIVE and wait, never double-spawn into the same worktrees; a repeat check that comes up empty again (optionally: no new Heartbeats in report.md) confirms death), do the branches/worktrees in `worktrees.txt` exist, is there a `BLOCKED-n.md` without a matching `ANSWER-n.md`? Summarize all missions to the user in ≤5 lines, delete CARRYOVER.md if present, then handle any `blocked`/`review` states (phases 5/6). Missions whose sessions died: respawn per the Phase 4 crash path with the salvage message "salvage what exists on the mission branches — run `git log` first."

## Phase 1 — Record the request

Identify the repository set without making product or architecture decisions. Create `$HUB/missions/<date>-<slug>/`, save the complete user ask and explicit constraints as `request.md`, create `MISSION.md` from the template (`Phase: pending`), and write `pending` to `state`. Fable owns the creative brainstorm after provisioning. If the repository set itself is materially ambiguous, ask before provisioning. The date-prefixed slug must be unique across missions/ and archive/.

## Phase 2 — Provision

1. List every repo the recorded request touches. `git -C <repo> rev-parse` must succeed — refuse non-git directories (tell the user).
2. **Repo conflict check:** if any of those repos appears in another mission whose state is `running`, `planned`, `executed`, `rework`, `blocked`, or `review` → leave this mission `pending`, tell the user it's queued, and launch it automatically when the conflicting mission archives (or enters `failed` — Phase 6f launches it at state-change).
3. Per repo: `git -C <repo> worktree add <umbrella>/.worktrees/<mission-slug>/<repo-name> -b orc/<mission-slug>` (`<umbrella>` = the hub's parent directory — the `<dir>` from Hub resolution) and append a line to `$HUB/control/<mission-slug>/worktrees.txt`: `<abs worktree>\t<branch>\t<base sha>\t<abs repo>` (base sha = `git -C <repo> rev-parse HEAD` at creation). Copy the finished manifest byte-for-byte to `$MISSION_DIR/worktrees.txt` for worker context. The control copy is the only broker/gate authority. Mirror the same rows into MISSION.md's table.
4. The FIRST repo (the design's center of gravity) is the **primary**; its worktree is the session cwd. If the primary repo already tracks `.claude/settings.json`, stop and tell the user — planting the mission hooks would mask the repo's own settings for the whole mission. Write the hooks into the **primary worktree only** (hooks load from the session's cwd): copy `${CLAUDE_PLUGIN_ROOT}/templates/worker-settings.json` to `<primary>/.claude/settings.json`, replacing `{{CONTROL_DIR}}` with the coordinator-only control directory, `{{WORKTREES}}` with the colon-joined absolute worktree paths, `{{MISSION_DIR}}` with the absolute mission dir, `{{GUARD_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/worker-guard.sh`, and `{{GATE_SCRIPT}}` with `${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-gate.sh`. Then validate the written file: `jq .` must parse it, `grep -F '{{'` must find nothing left unsubstituted, and both script paths must exist and be executable — a malformed settings file fails OPEN (hooks silently absent), so fix it before launching.
5. Copy `${CLAUDE_PLUGIN_ROOT}/templates/report.md` into the mission dir, filling only `{{MISSION_SLUG}}` and `{{TITLE}}` — deliberately leave the section placeholders for the worker to fill. Write BOTH briefs now, filling every `{{PLACEHOLDER}}`, including `{{CONTROL_DIR}}` and coordinator-owned `{{REVIEW_DIFFS}}` paths: `brief.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief-codex.md` (the Fable brainstorm/planner/reviewer session) and `brief-exec.md` from `${CLAUDE_PLUGIN_ROOT}/templates/brief-exec.md` (the executor). The context digest is curated: binding DECISIONS rulings, reference files/patterns, test commands per repo — never "read the whole repo." At go, freeze the executor brief in control; corrections before go travel through the same Fable session.
6. **Preflight (mandatory before launch):** run `${CLAUDE_PLUGIN_ROOT}/scripts/provision-preflight.sh --mission-dir <dir> --worktree <primary> [--worktree <other>]...`. It installs dependencies (npm ci / swift package resolve), creates in-worktree `.swift-caches/`, and runs each repo's full baseline OUTSIDE any sandbox, writing `baseline-attestation.json` into the mission dir. Exit 3 = baseline red: adjudicate each failure FIRST (pre-existing platform bug / sandbox-irrelevant noise / real breakage — real breakage means fix the repo or re-scope, not launch), record the ruling in DECISIONS.md, and fill the accepted-failure-set into brief-exec.md's `{{ACCEPTED_FAILURES}}` before spawning. Never launch over an unadjudicated red baseline.

## Phase 3 — Launch (plan stage)

Write `running` to `state` BEFORE spawning (a fast worker can write `blocked` first and be clobbered), then spawn the PLAN stage via Bash with `run_in_background: true`:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --control-dir $HUB/control/<mission-slug> --worktree <primary> [--worktree <other>]...`

Update MISSION.md `Phase:` and board.html. Tell the user the mission is off and you're available. **You are now free — behave like a normal session until a wake.**

## Phase 3g — Go gate (state=planned)

The plan stage exiting with `state=planned` is the pipeline's ONLY human pause. The worker left TWO artifacts: `plan.md` (what executes) and `plan-review.html` (the writing-plans Review Companion — what the user actually reads: decisions to tweak, data-model/interface/user-facing choices with alternatives; mechanical work collapsed). **Publish plan-review.html as a private artifact** (Artifact tool — strip any doctype/html/head/body skeleton the worker wrote and add the standard `data-theme` overrides; if the Artifact tool is unavailable, give the file path) and present it with a ≤5-line note (mission, repos touched, riskiest point) and ask for **go**. The mission stays `planned` — update MISSION.md + board.html and be free. If the user wants plan changes, resume the CLAUDE session with the correction (`spawn-worker.sh … --resume "<correction>"`) — it updates plan.md first, regenerates plan-review.html, and re-enters `planned` (re-publish the artifact to the same URL). On **go**: snapshot design.md, plan.md, and the rendered executor brief into the coordinator-only control directory as approved-design.md, approved-plan.md, and brief-exec.md; write their SHA-256 hashes to approved.sha256; verify them; write `running` to `state`; then spawn the EXEC stage:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --control-dir $HUB/control/<mission-slug> --worktree <primary> [--worktree <other>]... --stage exec`

Then **hands off until the process exits**: no polling, no reading heartbeats/worker output mid-run, no interim reviews, no status checks "just to see". The executor completes ALL plan tasks in one uninterrupted run and you are woken at exit (`executed`, `blocked`, or crash) — engaging earlier only burns tokens and can never change the outcome. The one review happens after `executed`.

## Phase 4 — Wake handling (event-driven)

The background spawn process exiting wakes you, even mid-conversation about something else — finish your sentence, then handle it. Read that mission's `state`:

- `planned` → Phase 3g (present plan, await the user's go).
- `executed` → **seamless, no user involvement**: verify the approved hashes and control manifest, generate coordinator-owned full diff snapshots, write `running` to `state`, then resume the claude session into review: `spawn-worker.sh --mission-dir <dir> --control-dir $HUB/control/<mission-slug> --worktree <primary> [...] --stage review --resume "The executor has finished — read report.md and the trusted review diff snapshots, then proceed to Stage 2 (REVIEW) per your original instructions."` (After a rework round: "The executor has addressed the F<n> findings — re-review per your original instructions.")
- `rework` → **seamless, no user involvement**: the reviewer left findings in report.md `## Code review`. Append `rework: <date>` to MISSION.md's Notes; on the 3rd rework of the same mission, STOP and escalate to the user instead (the loop isn't converging). Otherwise write `running` to `state`, then bounce to codex: `spawn-worker.sh --mission-dir <dir> --control-dir $HUB/control/<mission-slug> --worktree <primary> [...] --stage exec --resume "The reviewer recorded findings in report.md '## Code review' (items F<n>). Fix every finding per your brief's REWORK protocol."`
- `blocked` → Phase 5.
- `review` → Phase 6.
- State/Phase already `failed` → one-line note to the user; never Phases 5/6.
- Process exited with **rc=75** (`QUOTA_LIMIT` in its output) → NOT a crash: the worker hit a usage/session limit. Schedule a delayed retry of the SAME spawn (background compound like `sleep <seconds-until-reset> && spawn-worker.sh …` — the spawn must be the LAST FOREGROUND command in that compound, never `&`-ed, or the exit-wake is lost), note `quota-retry: <date>` in MISSION.md's Notes, and tell the user in one line. Do not count it toward crash strikes.
- Process exited but state still `running` → crash: check the LAST `stage:` line in `session.txt` to pick the backend, inspect `worker-output-*.json` / `worker-stderr.log` and the worktrees, then respawn = `spawn-worker.sh … --resume "<salvage message>"` (add `--stage exec` if the crashed stage was exec — it resumes the codex thread; headless transcripts usually survive a process crash). Only if the resume itself errors: append a clearly-marked `## Respawn addendum (<date>)` section to the crashed stage's brief with the salvage note — the ONLY sanctioned brief mutation, logged in DECISIONS.md — then spawn that stage fresh. At each crash wake, append a `crash: <date>` line to MISSION.md's Notes section (orchestrator-owned, survives carryover); 2 such lines → Phase 6f.

If multiple missions have exited, handle one wake fully (through its state + board update) before the next. Update MISSION.md + board.html on **every** state transition.

**Spawn wrapper discipline:** whenever you wrap a spawn/resume in a compound background command, the spawn must be the LAST FOREGROUND command of the compound — `&`-ing it inside detaches it from the tracked process and you lose the exit-wake.

## Phase 5 — Mediate

Invoke `orchestrator:orchestrator-mediation` for the triage rules. Write `ANSWER-<n>.md` next to the BLOCKED file, append the ruling to `$HUB/DECISIONS.md` (`## D-<seq> (<mission-slug>, <date>) — <question> / <answer> / decided-by: orchestrator|user`), write `running` back to `state` BEFORE resuming (a fast worker can write `blocked` first and be clobbered), then resume THE BACKEND THAT BLOCKED — check the last `stage:` line in `session.txt` and add `--stage exec` if it says exec:

`${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worker.sh --mission-dir <mission-dir> --control-dir $HUB/control/<mission-slug> --worktree <primary> [--worktree <other>]... [--stage exec] --resume "Read ANSWER-<n>.md in your mission directory and continue."`

## Phase 6 — Accept & merge (light acceptance, ~2 minutes — you do NOT re-review the code)

1. **Artifacts:** `plan.md` exists; `report.md` has `## Code review` with a real verdict and `## Verification` with real test output. Missing → resume the session naming exactly what's absent (`spawn-worker.sh … --resume`, as in Phase 5); also delete `$MISSION_DIR/.gate-blocks` when bouncing, so the gate's block budget is fresh for the retry; do NOT merge.
2. **Fence:** per `worktrees.txt` line, `git -C <worktree> diff <base>...HEAD --stat` stays within the design's declared scope; branch names match; the diff must not include `.claude/settings.json` (the planted hooks) — if a worker committed it, bounce the mission to remove it before merge (`spawn-worker.sh … --stage exec --resume` — it's a code change, so it goes to codex).
3. **Merge:** per repo in dependency order (worktrees.txt order, primary first, unless the design says otherwise): first require the user's live checkout clean and on its default branch; never switch or clean it for them. Before merging, route any verification that may write caches, snapshots, coverage, or generated artifacts to the same Codex executor. The coordinator may run only an explicitly attested read-only, externally isolated command. Merge with `--no-ff --no-commit`; commit on verified pass, or abort and resume the Codex executor with the exact failure. After it returns to `executed`, the normal Fable re-review runs. Two failed acceptance cycles enter Phase 6f.
4. **Cleanup — nothing temporary outlives the mission:** first delete the planted `<primary>/.claude/settings.json` (and the `.claude/` dir if now empty), then per `worktrees.txt`: `git -C <repo> worktree remove <worktree>` (if it still refuses over stray files, `git worktree remove --force` is safe post-merge) and `git -C <repo> branch -d orc/<mission-slug>`; remove the now-empty `.worktrees/<mission-slug>/`. Then run `${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator-gc.sh --hub $HUB` — it lists leftovers from PAST missions (archived but worktree/branch still present; this historically slips) so you can sweep them with `--clean`.
5. **Report** to the user: what shipped per repo, decisions made on their behalf (DECISIONS.md), test results, follow-ups from the report.
6. **Memory, exactly once per mission:** append learnings to `$HUB/MEMORY.md` as `## M-<seq> · ttl:<durable|mission> · <date>`; prune this mission's `ttl:mission` entries; mirror `ttl:durable` learnings into your global auto-memory.
7. Set state + MISSION.md `Phase:` to `accepted`, move the mission dir into `$HUB/archive/`, delete `$HUB/.carryover-notified` (a future 65% warning may fire again), regenerate board.html, then launch any `pending` mission this unblocked (Phase 2 conflict check).

## Phase 6f — Failed

Entered on 2 crash deaths, 2 failed acceptance cycles, or the user saying to kill a mission. On a user-kill the session is still RUNNING: first terminate the process (find it via `pgrep -f <session-id>` as in Phase 0, then kill it) before setting `failed`. Set state + MISSION.md `Phase:` to `failed`, notify the user with what exists (branches, worktrees, the report so far), and launch any `pending` mission this unblocked (Phase 2 conflict check) — don't wait for archive. `failed` does NOT count as a conflict in the Phase 2 repo-conflict check (branch names are per-slug, so a new mission on the same repo is safe). Keep worktrees/branches for salvage until the user decides; on their go-ahead, clean up as in Phase 6 step 4 and archive the mission dir.

## board.html

On every mission state change, regenerate `$HUB/board.html` from `${CLAUDE_PLUGIN_ROOT}/templates/board.html`: one row per mission at `<!-- ROWS -->` following the commented row shape (pill classes: `pending running planned executed rework blocked review accepted failed`; links into `missions/<slug>/`). Missions archive at acceptance, so accepted rows normally drop off the board in the same regeneration; if you choose to list recently archived missions, point their links at `archive/<date>-<slug>/` instead of `missions/<slug>/`.

## Carryover (context ≥ 65%)

When the context-watch hook fires: write `$HUB/CARRYOVER.md` from the template (mission list + states + session ids, unanswered BLOCKEDs, anything in-context-only), update each MISSION.md, then tell the user exactly: **"Context at 65% — open a new session and run `/orchestrate` to continue. Missions are unaffected."** Then stop supervising; do not start new work. Wakes arriving after the 65% notice get one line to the user ("mission X exited, state S — handle it from the new session"); do not run Phases 5/6 here.

## Non-negotiables

- Mission sessions never talk to the user; you never forward a session's raw output as a question — triage first.
- You never edit files inside a mission's worktrees while it runs; corrections go through ANSWER files. The claude stages can't either (guard-enforced) — every code change in a mission's history comes from the codex executor.
- You never engage with a running stage between wakes — no polling, no mid-run status reads, no interim reviews (token discipline; wakes are the only touchpoints). Review is once-per-`executed`, and findings go back to codex via `rework` — Fable only plans and reviews, codex is the only one who touches code.
- Only you write MEMORY.md, DECISIONS.md, board.html.
- Escalate to the user only for: scope changes, user-visible behavior, cost, or data. Everything else you decide and log.
- Hub writes (DECISIONS.md, MEMORY.md) go through the Edit/Write tools with plain wording and short commit messages — heredocs or sed one-liners whose text narrates sandbox behavior tend to trip the coordinator's own permission classifier and stall you.
- The staged pipeline is brief-driven: Fable brainstorms and plans, the executor implements the frozen plan with TDD and records verification, and the resumed Fable session runs the explicit same-session review checklist. The Stop-hook gate and coordinator acceptance are backstops, not the driver.
- Model assignments per stage are plugin constants — never "just this once" run execution on claude or review on codex.
