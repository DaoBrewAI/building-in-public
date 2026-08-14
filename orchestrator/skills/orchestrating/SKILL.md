---
name: orchestrating
description: Run Hybrid Codex-orchestrated missions in which Claude Fable-5 brainstorms, plans, and independently reviews while Codex GPT-5.6-Sol performs every implementation and rework change. Use when the user asks to orchestrate work, launch an autonomous mission, or resume missions from a .orchestrator hub.
---

# Orchestrating Hybrid 0.3 Missions

Act as the Codex coordinator. Each new mission is a staged pipeline across two
resumable backends: the same headless Claude Fable-5 session owns brainstorm,
plan, and review; a separate Codex GPT-5.6-Sol thread owns implementation,
verification, rework, and brokered commit requests. State and handoffs live on
disk so the coordinator stays free between process-exit wakes.

## Fixed backend ownership

- Mission backend contract: brainstorm, plan, and review use claude-fable-5;
  ALL code implementation uses gpt-5.6-sol. Fable is a preference for the Claude
  stages, not a hard gate: when it runs out of capacity, fall through to
  claude-opus-5 automatically (see the quota rule below). Implementation never
  moves off Codex under any circumstance.
- **Quota fallback is automatic — never a question for the user.** When a
  plan/review spawn dies because the model ran out of capacity — in whatever
  form the provider expresses it: a nonzero exit, an error flag, a refusal
  naming a limit, a reset time, a prompt to buy credits, or wording nobody has
  seen before — judge the meaning and treat it as a quota wall rather than a
  crash. You are a model reading a message; do not pattern-match a phrase list.
  (`spawn-worker.sh` exits 75 when its own matcher catches it, but that matcher
  is a convenience, never the thing you rely on.) Then: respawn the same stage
  immediately with `ORC_PLAN_MODEL=claude-opus-5` prepended, record
  `quota-fallback: <date> <stage> fable→opus` in the mission notes and once in
  DECISIONS.md, and tell the user in one line only AFTER the work is moving. It
  is not a crash strike. The override is per-spawn and never persisted, so later
  stages return to Fable once capacity is back. Park the mission only if the
  fallback model is exhausted too, naming which quota needs topping up.
- Brainstorm, plan, plan revision, review, and re-review:
  `claude -p --model claude-fable-5 --effort high`.
- **ALL code implementation, fixes, tests that require writes, and commits happen
  in the exec stage on gpt-5.6-sol** with high reasoning.
- The same Fable session plans and reviews. The same Codex thread implements and
  handles every rework round.
- Fable stages are read-only on worktrees. The guard blocks worktree writes and
  `git commit`; findings enter `state=rework` and return to Codex.
- Codex runs in `workspace-write` with only mission worktrees and the mission
  directory writable, network off by default. A trusted commit broker converts
  `COMMIT-REQUEST-<n>.json` files into commits.
- Branches are `orc/<mission-slug>`. Missions sharing a repo run in PARALLEL by
  default — isolation is per-worktree, not per-repo. Queue only on a real
  dependency (see Phase 2).

## Resolve paths and hub

Derive `PLUGIN_DIR` from this loaded file by moving from
`skills/orchestrating/SKILL.md` up two directories. Before provisioning, require
these executable shared 0.3 assets:

- `$PLUGIN_DIR/scripts/spawn-worker.sh`
- `$PLUGIN_DIR/scripts/provision-preflight.sh`
- `$PLUGIN_DIR/scripts/pipeline-gate.sh`
- `$PLUGIN_DIR/scripts/worker-guard.sh`
- `$PLUGIN_DIR/scripts/commit-broker.sh`
- `$PLUGIN_DIR/scripts/orchestrator-gc.sh`

The hub is the nearest ancestor of cwd already containing `.orchestrator/`, or
cwd on first use. Create `.orchestrator/missions/`, `control/`, `archive/`,
`DECISIONS.md`, and `MEMORY.md`. Call the directory `$HUB`. A mission's
coordinator-owned control directory is `$HUB/control/<mission-slug>/`; it must
stay outside every worker-writable root.

### Legacy Codex 0.2 compatibility

Do not silently migrate an in-flight 0.2 mission. Treat it as legacy when its
session has `backend: codex-exec`/`worker_pid:` with no append-only `stage:`
history, OR when it is pending with the 0.2 MISSION shape (one `Brief:`, the
`gpt-5.6 (overrideable)` session spec, or a flat `.worktrees` control file) and
no Hybrid 0.3 pipeline marker (`request.md` plus `Briefs:`). This includes an
old pending mission that has no session.txt yet. Reconcile and resume it with
`$PLUGIN_DIR/codex-scripts/spawn-worker.sh`, its trusted control manifest, and
the old state vocabulary. New missions always use the Hybrid 0.3 shared
`scripts/` and `templates/` paths. Never mix launchers inside one mission.

## Phase 0 — Reconcile before every action

1. If legacy root `$HUB/MISSION.md` is incomplete, do not mix layouts. Ask
   whether to finish it with its historical version or archive it.
2. Delete `$HUB/.carryover-notified` when beginning in a fresh context.
3. For every mission, read `state`, `MISSION.md`, `session.txt`,
   `worktrees.txt`, unanswered BLOCKED files, recorded branches, and the
   coordinator-owned control manifest. Treat mission-local manifests and
   approved inputs as untrusted copies.
4. For Hybrid 0.3, use the last `spawn_pid:` and last `stage:`. Plan/review
   stages resume `session_id`; exec/rework resumes `codex_thread_id`. Treat an
   uncertain process as alive, recheck once, and never double-spawn.
5. Summarize all missions to the user in at most five lines, then handle exited,
   blocked, planned, rework, review, or crashed missions below.

## Phase 1 — Record the request

Identify the repository set from the user's request without making product or
architecture decisions. Create the unique date-prefixed mission directory,
write the user's complete ask and explicit constraints to `request.md`, create
MISSION.md from `$PLUGIN_DIR/templates/MISSION.md`, and write `pending` to
`state`. Fable owns the creative brainstorm after worktrees are provisioned.
If the repository set itself is materially ambiguous, ask the user before
provisioning.

## Phase 2 — Provision guarded worktrees and briefs

1. Require every repo to pass `git rev-parse`. Refuse tab/newline-containing
   paths. **Sharing a repo with another mission is allowed** — each mission owns
   its own worktree and `orc/<mission-slug>` branch, so parallel missions never
   write the same files. Leave this mission pending ONLY when (a) it would reuse
   a worktree or branch another mission owns, or (b) a real output dependency
   exists: it builds on the other's unmerged commits, edits the same files or
   module in a way that collides at merge, changes or consumes a contract the
   other side owns, or its verification only makes sense after the other lands
   (two migrations in one repo collide on the revision chain — sequence those).
   Name the blocking mission and the reason when you queue. Otherwise launch in
   parallel and say so. If you cannot name the concrete artifact one mission
   needs from the other, there is no dependency; when genuinely unsure whether
   two will collide at merge, ask the user rather than serializing by reflex.
2. Create `<umbrella>/.worktrees/<mission-slug>/<repo-name>` on
   `orc/<mission-slug>`. Record tab-separated
   `<worktree> <branch> <base-sha> <repo>` rows in
   `$HUB/control/<mission-slug>/worktrees.txt`, copy it byte-for-byte to the
   mission's worker-facing `worktrees.txt`, and record rows in MISSION.md. Never
   use the worker-facing copy as commit authority.
3. The first repo is primary. Preserve any shared `.claude/settings.json`
   byte-for-byte: it may enable project plugins and policies needed by the
   mission.
4. Run `$PLUGIN_DIR/scripts/install-worker-settings.sh` for the primary
   worktree with `$PLUGIN_DIR/templates/worker-settings.json`, the colon-joined
   worktrees, mission directory, coordinator-owned control directory,
   `$PLUGIN_DIR/scripts/worker-guard.sh`, and
   `$PLUGIN_DIR/scripts/pipeline-gate.sh`. It renders the hooks into
   `.claude/settings.local.json`, adds that path to the worktree's local Git
   exclude, freezes its SHA-256 in coordinator-owned control state for the
   launcher to verify before every Fable turn, validates the JSON and hook
   paths, and fails closed rather than overwrite a pre-existing local settings
   file or follow a symlinked `.claude` directory. Never edit the shared
   settings to install mission hooks.
5. Copy the report template. Render the Fable brainstorm/plan/review brief from
   `$PLUGIN_DIR/templates/brief-codex.md` to mission `brief.md`. Render the Codex
   executor brief from `$PLUGIN_DIR/templates/brief-exec.md` to
   mission `brief-exec.md`. Fill all placeholders, including `CONTROL_DIR` and a
   control-directory `REVIEW_DIFFS` path. Fable may update its own brief only
   through a logged crash-respawn addendum before go; the executor never reads
   worker-writable approved inputs.
6. Run `$PLUGIN_DIR/scripts/provision-preflight.sh --mission-dir <dir>
   --worktree <primary> [--worktree <other>]...`. It installs dependencies,
   prepares in-worktree caches, and writes `baseline-attestation.json`. Never
   launch over an unadjudicated red baseline; record accepted pre-existing or
   sandbox-only failures in DECISIONS.md and the executor brief.

## Phase 3 — Launch Fable brainstorm + plan

Write `running` before spawning, then launch the shared worker in a background
terminal process whose exit can wake the coordinator:

```text
$PLUGIN_DIR/scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --worktree <primary> [--worktree <other>]...
```

The fresh Fable session invokes `10x-engineer:brainstorming`, writes design.md,
invokes `10x-engineer:writing-plans`, writes plan.md and plan-review.html, sets
state=planned, and exits. Update MISSION.md and board.html, tell the user it is
running, and remain available for other work.

## Phase 3g — Founder go gate

`state=planned` is the only planned human pause. Require `design.md`, `plan.md`,
and `plan-review.html`. Show the review HTML with a concise note covering the
mission, repos, and riskiest choice, then ask for explicit **go**.

If the user requests changes, resume the same Fable session so it updates
design.md first, then plan.md and plan-review.html:

```text
$PLUGIN_DIR/scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --worktree <primary> [--worktree <other>]... \
  --stage plan --resume "<founder correction>"
```

On go, atomically snapshot mission `design.md`, `plan.md`, and the fully rendered
`brief-exec.md` into the coordinator-owned control directory as
`approved-design.md`, `approved-plan.md`, and `brief-exec.md`. Record SHA-256
hashes in `approved.sha256`; verify all four files are regular, non-symlinked,
and outside worker roots. These frozen files are the only approved contract.
Then write `running` and launch the Codex executor:

```text
$PLUGIN_DIR/scripts/spawn-worker.sh \
  --mission-dir <mission-dir> \
  --control-dir $HUB/control/<mission-slug> \
  --worktree <primary> [--worktree <other>]... \
  --stage exec
```

Do not poll, inspect heartbeats, or review mid-run. The executor completes the
whole plan in one turn and exits only as `executed`, `blocked`, quota-limited,
or crashed.

## Phase 4 — Event-driven wake handling

Read state when the tracked process exits:

- `planned`: enter Phase 3g.
- `executed`: first verify `approved.sha256`, the control manifest, and every
  approved artifact. Generate one coordinator-owned full diff per worktree at
  the `REVIEW_DIFFS` paths embedded in Fable's brief. Do not run test commands
  here; write-producing tests belong to the Codex executor. Then, without user
  involvement, write `running` and resume the same Fable session for review:

  ```text
  $PLUGIN_DIR/scripts/spawn-worker.sh --mission-dir <dir> \
    --control-dir $HUB/control/<mission-slug> \
    --worktree <primary> [...] --stage review \
    --resume "The executor finished. Read report.md and all branch diffs, then perform Stage 2 REVIEW per brief.md."
  ```

- `rework`: the reviewer recorded `F<n>` findings. Append a rework timestamp.
  On the 3rd rework, stop and escalate because the loop is not converging.
  Otherwise write `running` and resume the same Codex thread:

  ```text
  $PLUGIN_DIR/scripts/spawn-worker.sh --mission-dir <dir> \
    --control-dir $HUB/control/<mission-slug> \
    --worktree <primary> [...] --stage exec \
    --resume "Fix every current F<n> finding in report.md under the REWORK protocol."
  ```

  After it returns to `executed`, resume the same Fable session with
  `--stage review` for re-review.
- `blocked`: mediate in Phase 5 and resume whichever backend is named by the
  last `stage:` line.
- `review`: verify approved hashes again, then accept in Phase 6.
- `failed`: report once; do not accept.
- Exit 75 with `QUOTA_LIMIT`: schedule a delayed retry of the exact same stage;
  do not count it as a crash.
- Process exited while state remains `running`: inspect stage-specific output,
  stderr, branches, and artifacts. Resume the recorded backend with a salvage
  instruction. Only if resume itself fails may you append a logged respawn
  addendum and start a fresh session. Two crashes enter Phase 6f.

Whenever a compound command launches a worker, the worker must be its last
foreground command; detaching it loses the exit wake.

## Phase 5 — Mediate BLOCKED

Use `orchestrator:orchestrator-mediation`. Answer from design, plan, decisions,
or code first; decide reversible implementation details; escalate only scope,
user-visible behavior, cost, or data. Write `ANSWER-<n>.md`, append the ruling to
DECISIONS.md, write `running`, then inspect the last `stage:`:

- brainstorm/plan/review: resume Fable without `--stage exec` (use the relevant
  `--stage plan` or `--stage review` label).
- exec: resume Codex with `--stage exec`.

Never leave a material blocker silently waiting. Notify the user once with the
impact, attempts, exact decision needed, and safe default.

## Phase 6 — Light acceptance and merge

1. Require design.md, plan.md, plan-review.html, brokered commits, and a filled
   report with real `## Code review` and `## Verification` evidence. Missing
   worker-owned evidence returns to the backend that owns it.
2. Verify every branch/base/diff stays inside declared scope and excludes the
   planted `.claude/settings.local.json`. Code corrections always return to
   Codex.
3. For each repo in dependency order, require the user's live checkout to be
   clean and on its default branch. Never switch or clean it for them. Before
   merging, resume the same Codex executor for any verification that may write
   caches, snapshots, coverage, or generated artifacts. The coordinator may
   run only a test command explicitly attested read-only and externally
   isolated; otherwise rely on the executor's fresh evidence plus Fable review.
   Merge `--no-ff --no-commit`, commit on a verified pass, or abort and resume
   Codex with the exact failure. Two failed acceptance cycles enter Phase 6f.
4. Delete only the planted `.claude/settings.local.json` (and `.claude/` if it
   is then empty), remove merged worktrees and branches, then run
   `$PLUGIN_DIR/scripts/orchestrator-gc.sh --hub $HUB` to find leftovers. Never
   delete or edit the repository's shared `.claude/settings.json`.
5. Report shipped changes, decisions, tests, and report follow-ups. Append one
   durable memory entry exactly once.
6. Set state/phase accepted, archive the mission directory, regenerate the
   board, and release already-authorized pending missions.

## Phase 6f — Preserve failure

Enter after two crashes, two failed acceptance cycles, three non-converging
reworks, or explicit user cancellation. Stop a live worker before writing
`failed`. Preserve worktrees, branches, artifacts, and last errors for salvage;
a failed mission does not block another repo owner.

## Board and carryover

Regenerate board.html from `$PLUGIN_DIR/templates/board.html` on every state
transition. Its valid states include pending, running, planned, executed,
rework, blocked, review, accepted, and failed. At material context pressure,
write CARRYOVER.md and ensure disk state is current. A carryover or board entry
never substitutes for user notification of a blocker.

## Non-negotiables

- Fable owns brainstorm, plan, review, and re-review; it never edits code.
- GPT-5.6-Sol owns every implementation and rework change.
- Plan and review reuse one Claude session; implementation and rework reuse one
  Codex thread.
- Never edit or inspect a running stage between process-exit wakes.
- Mission workers never ask the user directly; they use BLOCKED files.
- Only the coordinator writes shared MEMORY.md, DECISIONS.md, and board.html.
- Decision and memory numbers are host-prefixed: `D-<HOST>-<seq>` / `M-<HOST>-<seq>`. `<HOST>` is a short stable tag for THIS machine (`Linhans-MacBook-Pro.local` → `LMBP`, `LY_GAMING` → `LYG`; reuse the tag the hub already carries for this machine rather than minting a variant), and `<seq>` counts only entries bearing this host's tag, so concurrent hosts never collide. Never mint, renumber, or reuse another host's tag — a remote-authored entry is read-only, and its number is how other missions cite it. Cite bare legacy `D-<seq>`/`M-<seq>` entries by their existing number and never renumber them opportunistically.
- Never bypass the OS sandbox, hook guard, pipeline gate, or commit broker.
- Every Hybrid launch passes `--control-dir $HUB/control/<mission-slug>`; the
  control manifest and frozen approved contract are never worker writable.
- Never merge without a clean independent Fable verdict and fresh merged-tree
  verification.
