# Codex Loop Engineering

Run multi-step Codex work from an inspectable execution contract: a user outcome,
coherent checkpoints, dependency-aware workers, evidence and verified handoffs.

The 2026-09-08 update adapts this starter to GPT-6: strong planning/review in the
supervisor, task-sized reasoning for workers, **Standard/non-Fast by default**,
and tool/computer-use rules that preserve the user's real environment.

## Start small

From the project root:

```bash
PROJECT_NAME="my-project" LOOP_DIR="docs/loop/my-experiment" \
  bash /path/to/codex-loop-engineering/install.sh
```

Fill in the objective, scope, acceptance and authorized phases. Installing files
does not authorize implementation. For planning only, keep `mode: plan` and
`execution_authorized: false`. Auto-chain defaults off; set `AUTO_CHAIN=true`
only when the current loop is authorized to create continuation tasks.

For a concurrent DAG, add `DAG_TEMPLATE=true` to install the optional execution
manifest. Run the read-only checker:

```bash
python /path/to/codex-loop-engineering/scripts/loop_doctor.py \
  --loop-dir docs/loop/my-experiment --json
```

After authorizing execution, ask Codex to continue that named loop. The skill
reads the current contract and releases only eligible work. Do not use it as an
excuse to turn a one-off edit into a multi-session project.

## Session defaults

| Work | Starting choice |
|---|---|
| Supervisor planning and acceptance | User-selected model/effort, including supported GPT-6 Ultra |
| Ambiguous runtime, identity, recovery, integration | GPT-6 Astra medium |
| Clear interfaces, bounded adapters/UI/tests | GPT-5.6 Sol high |
| Speed for every new session | Standard, Fast off unless explicitly requested |

These are routing defaults, not benchmark claims. Verify model/effort/tier in the
actual launch before mutations. Never inherit Ultra or Fast just because the
parent used them. No automatic daytime or overnight Fast transition.

## What stays, what changed

- Keep goal/tracker/constraints/handoff, scoped checkpoints, meaningful tests,
  product alignment and verified continuation.
- Keep linear work when dependent; use a DAG when independent lanes are declared.
- Replace all-workers-Ultra/Fast and day/night model rules with explicit per-node
  policy and Standard defaults.
- Replace unchecked-box-only parallel dispatch with acceptance dependencies,
  file ownership, resource reservations and launch IDs.
- Distinguish plan/review from execution and source/tests from current live work.
- Respect browser-profile constraints across computer use, CLI, QA and rendering.

## Install the reusable skill

```bash
bash /path/to/codex-loop-engineering/install-codex-skill.sh symlink
```

The installed target must point to the version you intend to use. Check symlinks
when source and installed behavior differ. Publishing the source does not
automatically update an older local checkout.

## Reference

- [Skill entry point](SKILL.md)
- [Session policy](references/session-policy.md)
- [DAG contract](references/dag-contract.md)
- [Tool and computer use](references/tool-use.md)
- [Setup and migration](codex-auto-chain-session-handoff-setup.md)
- [Templates](templates/)

Validate helpers locally with:

```bash
python -m unittest discover -s codex-loop-engineering/tests -v
```

The checker never starts sessions or changes files. It validates declared policy;
the supervisor still verifies authority, evidence and actual runtime settings.
An older execution manifest must add `execution_authority_ref` for authorized
execute mode and each node's `owner`, `outcome`, `acceptance_criteria`, `verifier`,
`max_attempts` and `read_only` fields before dispatch.
