---
name: orchestrating
description: Run Codex-orchestrated missions - brainstorm an ask, provision guarded git worktrees, launch one autonomous resumable codex exec thread per mission, mediate material blockers, and accept or merge verified work. Use when the user asks to orchestrate work, launch an autonomous mission, or resume missions from a .orchestrator hub.
---

# Orchestrating Codex Missions

Act as the coordinator. Each mission is one persistent `codex exec` thread that
owns plan → implementation → self-review → verification → report. The trusted
launcher validates the result and creates mission commits after the sandboxed
turn ends.
Keep shared state on disk and never edit a running mission's worktrees.

## Resolve paths and constants

Derive `PLUGIN_DIR` from this loaded file: move from
`skills/orchestrating/SKILL.md` up two directories. Verify that
`$PLUGIN_DIR/codex-scripts/spawn-worker.sh` exists before provisioning.

- Default worker model: `gpt-5.6`, reasoning `xhigh`. Operators may override
  these with `ORC_CODEX_MODEL` and `ORC_CODEX_EFFORT`.
- Branch name: `orc/<mission-slug>` in every involved repo.
- Allow at most one `running`, `blocked`, or `review` mission per repo.

The hub is `<dir>/.orchestrator/`, where `<dir>` is the nearest ancestor of the
current directory that already contains `.orchestrator/`; otherwise use the
current directory. Create `missions/`, `control/`, `archive/`, `DECISIONS.md`, and
`MEMORY.md` on first use. Call it `$HUB`.

## Phase 0 — Reconcile before every action

1. If a legacy root `$HUB/MISSION.md` is incomplete, do not mix layouts. Ask
   whether to finish it with the historical plugin or archive it.
2. For every `$HUB/missions/*/`, read `state`, `MISSION.md`, `session.txt`, and
   its coordinator-owned `$HUB/control/<mission-slug>.worktrees`. Treat the
   mission-local `worktrees.txt` as an untrusted worker-facing copy and require
   it to match the control manifest.
3. Treat a worker as alive only when its recorded `worker_pid` is numeric,
   `kill -0 <pid>` succeeds, and `ps -p <pid>` identifies the worker wrapper or
   Codex child. When uncertain, recheck once; never double-spawn into the same
   worktrees.
4. Reconcile missing worktrees, unmatched `BLOCKED-<n>.md` files, and stale
   `running` states. Summarize all missions to the user in at most five lines,
   then handle `blocked`, `review`, or crashed missions below.

If a terminal session handle from launch still exists, poll it non-blockingly
for fresh output. Codex does not guarantee a process-exit callback into a
dormant conversation, so disk state and the wrapper notification are the
portable wake mechanism.

## Phase 1 — Brainstorm and record the mission

Use `10x-engineer:brainstorming` on the ask. Save the validated design as
`$HUB/missions/<date>-<slug>/design.md`. The date-prefixed slug must be unique
across `missions/` and `archive/`. Create `MISSION.md` from the Codex template,
set phase/state to `pending`, and record explicit acceptance criteria and
non-goals. This design is orchestration state outside the mission repositories;
do not commit it during the brainstorming workflow.

## Phase 2 — Provision guarded worktrees

1. List each repo touched by the design. Require `git -C <repo> rev-parse` to
   succeed. Reject repo, hub, worktree, or plugin paths containing a tab or
   newline because the tab-separated manifest cannot represent them safely.
2. If another nonfailed mission already owns a repo, leave this mission pending
   and launch it only after the conflict clears.
3. For each repo, create
   `<umbrella>/.worktrees/<mission-slug>/<repo-name>` on
   `orc/<mission-slug>`. Append tab-separated
   `<worktree> <branch> <base-sha> <repo>` rows to the coordinator-owned
   `$HUB/control/<mission-slug>.worktrees`, which must be outside every worker
   writable root. Copy it byte-for-byte to the mission's `worktrees.txt` for
   worker context. Never use the worker-facing copy as commit authority.
4. Verify `pipeline-gate.sh`, `mission-commit.sh`, and `spawn-worker.sh` are
   executable. The worker must not create commits: Codex workspace-write keeps
   linked-worktree Git metadata read-only. The launcher runs the artifact gate
   after the turn. Once the process is dead, the coordinator inspects the diff
   and invokes the protected-path audit/commit broker with host approval outside
   the worker sandbox.
5. Copy the Codex `report.md` template and generate an immutable `brief.md` with
   all placeholders filled. Curate only binding decisions, relevant file
   patterns, known hazards, acceptance criteria, and exact test commands.

The launcher uses Codex `workspace-write`, adds only the declared worktrees and
mission directory as writable roots, replaces inherited additional writable
roots with an empty list, excludes implicit `/tmp` and `$TMPDIR` write access,
and disables interactive approvals. It
never disables the sandbox or bypasses hook trust. Existing hooks retain their
normal Codex trust behavior and are not part of the mission security boundary.

## Phase 3 — Launch

Write `running` before starting the process. Run the wrapper with the terminal
tool using a short yield so the coordinator regains control:

```text
$PLUGIN_DIR/codex-scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-manifest $HUB/control/<mission-slug>.worktrees \
  --worktree <primary> [--worktree <other>]...
```

Record a returned terminal handle in `terminal-handle.txt` when the host exposes
one. Update `MISSION.md` and `board.html`, tell the user the mission is running,
and remain available for other coordination work.

## Phase 4 — Completion or crash handling

On terminal completion, notification, a user status request, or a later
orchestrator invocation, read `state`:

- `blocked`: mediate in Phase 5.
- `review`: accept in Phase 6. If the post-turn gate failed, resume with its
  exact error first.
- `failed`: report it once and preserve worktrees.
- `running` with a live PID: leave it alone.
- `running` with a dead PID: inspect the latest `worker-output-*.jsonl`, stderr,
  working-tree diffs, and artifacts. Resume the recorded `thread_id` with a salvage
  instruction. If the thread cannot resume, append a clearly marked respawn
  addendum to `brief.md`, log the decision, and start a fresh thread.

Record each crash in `MISSION.md`; two crashes enter Phase 6f.

## Phase 5 — Mediate

Use `orchestrator:orchestrator-mediation`. Write `ANSWER-<n>.md`, append the
ruling to `DECISIONS.md`, write `running` before resume, then run:

```text
$PLUGIN_DIR/codex-scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-manifest $HUB/control/<mission-slug>.worktrees \
  --worktree <primary> [--worktree <other>]... \
  --resume "Read ANSWER-<n>.md in your mission directory and continue."
```

### Blocker notification contract

Never leave a mission silently waiting in `blocked`.

1. Attempt to unblock autonomously first: inspect the blocker, design, plan,
   code, prior decisions, logs, and safe in-scope alternatives. If the answer is
   already determined by approved scope and does not change user-visible
   behavior, cost, data semantics, or authority, write the ruling and resume the
   worker without interrupting the user.
2. If the blocker still requires user judgment, new authority, external action,
   or a material scope/product/data/cost decision, update `MISSION.md`, preserve
   `blocked`, regenerate `board.html`, and notify the user immediately in the
   active conversation. Include: what is blocked, impact, what was tried, the
   exact decision/action needed, and the safe default while waiting.
3. Do not rely on disk state, a board update, a worker notification, or a future
   status request as the notification. Do not keep polling an unchanged blocker
   without telling the user. End the coordinator turn with the blocker when no
   other useful in-scope work can continue.
4. Notify once per new or materially changed blocker. Do not spam repeated
   notifications for unchanged state, but never suppress the first actionable
   notification.

## Phase 6 — Accept and merge

1. Require `plan.md` and a filled `report.md` with Code review and Verification
   evidence. Resume the worker with exact missing items instead of filling them.
   Re-run `pipeline-gate.sh` as a deterministic check.
2. For every manifest row, verify branch, base, and uncommitted diff scope.
   Reject `AGENTS.md` or `.codex/` policy changes unless they were explicit
   mission requirements approved by the user.
3. Only after the worker is dead and the diff passes inspection, run the
   following through the host's approval/escalation mechanism:

   ```text
   $PLUGIN_DIR/codex-scripts/mission-commit.sh \
     --mission-dir <mission-dir> \
     --control-manifest $HUB/control/<mission-slug>.worktrees
   ```

   This lets one vetted command write linked-worktree Git metadata outside the
   coordinator sandbox. Do not grant the worker broader permissions. Require
   `commits.txt` and verify one brokered commit SHA per manifest row.
4. In dependency order, require each user's live checkout to be clean and on
   its default branch. Never switch or clean it for them. Merge with
   `--no-ff --no-commit`, run the repository's full verification, then commit on
   pass or `git merge --abort` and resume the worker on failure.
5. Remove worktrees and delete merged mission branches.
6. Report changes, logged decisions, verification evidence, and suggested
   follow-ups. Append durable learnings once to `$HUB/MEMORY.md`.
7. Set state/phase to `accepted`. Move the trusted control manifest into the
   stopped mission directory as `worktrees.trusted.txt`, move the mission into
   `archive/`, regenerate the board, and release newly unblocked pending
   missions.

Two failed acceptance cycles enter Phase 6f.

## Phase 6f — Preserve a failed mission

Enter on two crashes, two failed acceptance cycles, or an explicit user kill.
Terminate a live wrapper before setting `failed`. Report branches, worktrees,
artifacts, and last errors. Keep them for salvage until the user authorizes
cleanup; a failed mission does not block a new mission on the same repo.

## Board and carryover

Regenerate `$HUB/board.html` from the Codex board template on every state
transition. Before a manual task handoff or when Codex reports material context
pressure, write `CARRYOVER.md` and make sure every mission's durable state is
current. A carryover file or board entry never substitutes for the blocker
notification contract above. Automatic Codex compaction is safe because Phase 0
reconstructs state from disk.

## Non-negotiables

- Workers never ask the user directly; they use the BLOCKED protocol.
- Never edit a running worker's worktrees; corrections go through ANSWER files.
- Only the coordinator writes `MEMORY.md`, `DECISIONS.md`, and `board.html`.
- Escalate only scope, user-visible behavior, cost, or data decisions.
- Self-unblock safe in-scope questions; if a blocker still needs the user, notify
  immediately and never wait silently.
- The worker pipeline starts with `10x-engineer:writing-plans` and includes TDD,
  working-tree code review, verification, commit checkpoints, and a filled
  report; the trusted launcher creates the mission commits afterward.
