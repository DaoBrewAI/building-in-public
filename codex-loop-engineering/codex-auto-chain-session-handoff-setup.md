# Codex loop setup and migration

The maintained behavior lives in [SKILL.md](SKILL.md) and its references. This
guide covers installing the contract and migrating older loops without erasing
their history. Templates have one source in [templates/](templates/).

## Install a new scoped loop

```bash
PROJECT_NAME="my-project" LOOP_DIR="docs/loop/my-experiment" \
  AUTO_CHAIN=true DAG_TEMPLATE=true \
  bash /path/to/codex-loop-engineering/install.sh
```

The default writes goal/tracker/constraints/handoff. `DAG_TEMPLATE=true` also
copies an optional `execution.json` starting in plan mode. Existing files are
preserved unless `OVERWRITE=true` is explicitly supplied; do not use overwrite
to refresh an active loop. The installer never grants execution authority.

Fill in the actual outcome, non-goals, input/source versions, acceptance, write
ownership, resources and budget. Set the authorized phase set only from the
user's current request. Auto-chain permission covers continuation, not additional
scope, provider spending or external actions.

```bash
python /path/to/codex-loop-engineering/scripts/loop_doctor.py \
  --loop-dir docs/loop/my-experiment --json
```

A valid DAG has no cycles or missing dependencies, no conflicting active owners,
and explicit Standard session settings. Candidate scheduling is still subject to
evidence and launch-policy verification.

## Migrate an existing loop

1. Read all four current files and the named product authority; preserve original
   checkpoints and evidence. Identify whether the user wants plan, review or execute.
2. Resolve conflicting old launch policies. Remove inherited all-workers-Ultra,
   forced Fast, and automatic daytime Fast rules from active instructions. Keep
   historical observations explicitly historical.
3. Choose each node's model/effort and record Standard/non-Fast. Preserve the
   supervisor's user-selected reasoning without spreading it to workers.
4. Keep a linear tracker if it fits. For a DAG, declare dependencies, write roots,
   exclusive resources and acceptance before launching independent workers.
5. Reconcile active/provisional task IDs before creating anything. Do not replace
   a still-running worker just because a local transcript is stale.
6. Update handoff, run the checker and verify the actual next launch. Do not
   assume editing shared configuration changed an already-running task.

## Handoff requirements

Capture the exact repo/worktree/base and running build where relevant, installed
skill version, accepted checkpoint evidence, remaining uncertainties, next scoped
node, requested/effective settings and resource reservations. Keep source, tests,
live user flow, external action and business result separate.

Only the Supervisor releases successors. Workers return their bounded findings
and artifacts. Use one integrator for common interfaces and preserve the last
good output when later work fails.

## Model and computer-use constraints

See [session policy](references/session-policy.md) for current defaults and
host-specific Ultra/Fast handling. See [tool use](references/tool-use.md) for
existing-profile requirements and real UI/content evidence. Do not enable a new
browser or permission as a workaround for a failed tool.

## Publishing or updating the skill

Keep unrelated checkout changes out of the publish. If source checkouts are
dirty/diverged, use a clean worktree at the current publication base and stage
only this skill's intended files. Verify the remote commit and installed content
separately. A new experiment session should read the published/installed version
that the handoff names.

If the user requested skill publication before experiment sessions, do not create
those sessions until publication and installed-version checks complete. That
order does not authorize publishing experiment code.

## Troubleshooting

| Observation | Next useful check |
|---|---|
| Model/tier differs from request | Inspect launch inputs and actual task context; hold mutations |
| Every worker inherits Ultra/Fast | Remove stale active defaults and declare per-node policy |
| A successor starts too early | Check accepted predecessors and current authorized phase |
| Parallel workers collide | Check both write roots and exclusive runtime/account resources |
| Local and deployed behavior disagree | Compare loaded build/config and source versions separately |
| Browser tools lose the account | Identify the permitted existing instance/profile; do not create another |
| Long context repeatedly rescanned | Scope the worker packet and reopen only decisive source evidence |

The repository contract, not an old memory entry, controls continuation.
