# {{PROJECT_NAME}}: tracker

## Checkpoints

- [ ] CP1: Reconcile current source, runtime and decisive acceptance evidence.

Expand only into coherent accepted scope. `[~]` is active, `[x]` accepted with
evidence, `[!]` blocked. An execution finishing is not automatically acceptance.

## Dependencies and ownership

Default: linear. For concurrent lanes, fill execution.json and declare each
node's outcome, owner, dependencies, acceptance/verifier, attempt limit, write
paths and any exclusive resources before launch. A node with no write paths must
declare `read_only: true`; an empty resource list is valid when nothing is exclusive.

| Node | Depends on | Owner | Write paths/resources | Model/effort/tier | Acceptance/evidence |
|---|---|---|---|---|---|
| CP1 | none | Supervisor-assigned | declare before execution | Astra medium / Standard | define before execution |

## Current next action

Read the current contract and finish CP1's scope. Do not implement while mode is
plan/review. Only release authorized nodes with accepted predecessors and no
existing launch reservation or active task.

## Evidence log

| Node | Source/build | Check | Result | Evidence | Accepted by |
|---|---|---|---|---|---|
