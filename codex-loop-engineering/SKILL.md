---
name: codex-loop-engineering
description: Plan, execute, review and continue repo-local Codex checkpoints from durable goal, tracker, constraints and handoff files. Use for multi-session work, dependency-aware parallel lanes, verified handoffs and stuck continuation diagnosis; not for a one-off edit or as permission to execute a plan.
---

# Codex Loop Engineering

Version: 2026-09-08. The user sets the outcome and authority; the loop makes
execution, evidence and continuation inspectable. Announce use briefly.

## Establish the current contract

Read the named loop, otherwise inspect `docs/loop/`, in this order:

1. `goal.md`: user outcome, acceptance and non-goals.
2. `tracker.md`: checkpoint, dependencies and evidence.
3. `constraints.md`: scope, environment, tools, budgets and Git policy.
4. `handoff.md`: source/runtime, completed work and next action.
5. The exact product/source authority named by those files.

Use `python <skill>/scripts/loop_doctor.py --loop-dir <loop> --json` for
orientation, then read the relevant source. It does not prove acceptance or
grant permission. With `execution.json`, it also checks the DAG, ownership,
resource reservations and session policy.

Determine the mode explicitly: **plan**, **review**, or **execute**. Plan/review
does not authorize code changes, provider runs, app actions or new execution
sessions. A historical GO or quoted auto-chain flag cannot override a current
stop. Do not create a Codex Goal unless the user requested one.

Install a missing loop only when asked to set one up. For a superseding
experiment, preserve the old history and establish a fresh scoped contract when
authorized; do not restart stale controllers or wholesale-overwrite a handoff.

## Use GPT-6 for judgment, not repeated ceremony

Read [session policy](references/session-policy.md) when selecting or launching
sessions. Defaults:

- Preserve the user's selected supervisor model/effort. A GPT-6 Ultra supervisor
  can plan and arbitrate without making all workers Ultra. UI labels are not
  automatically valid API parameters.
- Use `gpt-6-astra` **medium** for uncertain cross-module diagnosis, identity,
  recovery and integration; use `gpt-5.6-sol` **high** for bounded work after its
  interface and acceptance are clear. Honor user overrides and host support.
- **Fast is off by default at every hour**, for all new continuations/workers.
  Request `service_tier: default` and Fast false where exposed. Only an explicit
  user instruction enables Fast; there is no daytime automatic return to Fast.
- Inspect relevant context once and pass scoped evidence to workers. Do not
  copy whole repos/conversations into every worker or repeat broad audits
  without a new question.
- Ask only when the missing answer changes scope, authority, architecture or an
  irreversible choice; resolve routine details within current authorization.
- Mid-turn input steers the active outcome. Stop an affected lane when its
  authority changes and cancel abandoned successors.

GPT-6 model features do not automatically appear in every host. Use only exposed
tools/arguments. Async orchestration allows other **independent** work while a
tool runs; it does not remove dependencies or turn a pending call into success.

## Choose linear work or a DAG

One coherent checkpoint is the execution unit. Use a linear loop for dependent
steps; use a DAG when independent work can save time or improve evidence.
For multiple lanes/sessions, read [the execution contract](references/dag-contract.md).

Before dispatch, fix each node's outcome, inputs, write paths, exclusive
resources, dependencies, acceptance, model/effort/tier, attempt limits and owner.

- One Supervisor releases work; one integrator owns common interfaces and
  acceptance. Workers do not each create another controller.
- Start with at most two execution workers unless otherwise chosen. File-disjoint
  work can still conflict on a browser, port, state root or external account.
- Only accepted predecessors release successors. A returned task, passing test
  or existing artifact does not by itself satisfy user/business acceptance.
- Split a checkpoint before escalating effort when it spans multiple outcomes,
  roughly 12+ production files or 2,000+ production lines, or combines a storage
  authority change with an unrelated feature.
- Repairs are bounded attempts inside a node. Keep the dependency graph acyclic;
  repeated failure needs a scoped repair/replan, not infinite retries or duplicate
  sessions.

The checker outputs scheduling candidates, not permission. Verify the actual
evidence, user authority and effective settings before releasing them.

## Execute and verify one slice

1. Record checkout/branch/SHA and relevant running build/configuration. A worktree
   is another checkout, not automatically a new branch. Use isolated development
   when appropriate; respect explicit direct-branch rules and unrelated work.
2. Reproduce a behavior change with a meaningful focused test/probe; make the
   smallest coherent change on owned files using relevant skills.
3. Batch independent reads/calls; keep mutations, dependencies, approvals and
   waits ordered. Do not replay completed external work.
4. Run declared checks. Broaden only for changed risk, failures or unresolved
   evidence; do not repeatedly run a full suite for a small edit.
5. Get an independent changed-slice review for material work. Check requirements
   against source/evidence, not the worker's success label.
6. Run a compact alignment gate against exact product authority, local derivations,
   authorized scope and result. Classify material commitments as aligned, partial,
   conflicting or not implemented. Resolve conflicts before successors; don't
   reinterpret the goal to match the output.
7. Update tracker/handoff with changes, commands, evidence, limitations and the
   exact next checkpoint. Commit/push only when authorized; push is not deployment.

For connectors, browser/native apps or media tools, read
[tool and computer use](references/tool-use.md). Existing-profile requirements
apply across CLI, QA and rendering; stronger computer use grants no new access.

## Continue within authorized work

Auto-chain applies when the user requested multi-session continuation or approved
it in the current loop, not to every ordinary task. Use internal subagents for
bounded subtasks; create visible app tasks only when requested or covered by that
loop's session authorization.

Persist a launch reservation and the ready node, source/skill version, settings
and scope before creation. A returned ID is provisional: verify the task exists,
started normally, read the intended contract and has the intended cwd/model/effort
and non-Fast launch state. Workers hold production mutations until that gate
passes. Session policy covers hosts that do not expose every field. Stop a wrong
launch; do not silently accept it or create unlimited replacements.

Use bounded event waits with cursors, not repeated full transcripts. Keep user
communication responsive. Release successors after recorded acceptance, not
merely a completion event.

Name the exact blocker and continue independent authorized lanes where possible.
Stop dependent work on user stop, missing authority/credentials/data, a disallowed
runtime, destructive/out-of-scope action or exhausted budget. A permission failure
is not a reason to try another access path. Already-authorized routine actions
do not need another approval.

For unattended/overnight work, first freeze the allowed phase set, limits,
notifications and review points. Use at most one authorized supervisor monitor;
never schedule one without a user request. Standard/non-Fast remains the default.

## Close with observable results

Report what actually ran, what changed, evidence and the remaining gate. Keep
authored source, tests, current live behavior, external action and business
outcome separate. Preserve the last good artifact and actionable state on failure.

The [setup guide](codex-auto-chain-session-handoff-setup.md), installer and
[templates](templates/) support this contract. Existing four-file loops remain
readable. Migrate stale settings explicitly and validate changes before publishing.
