# Orchestrator Risk-Tiered 10x Gates Implementation Plan

> **For Codex:** REQUIRED SKILL: Use 10x-engineer:executing-plans to implement this plan task-by-task.

**Goal:** Enforce a consistent 10x implementation/review/status-truth/merge workflow with durable HTML and next-step artifacts in every orchestrated mission.

**Architecture:** Keep worker evidence enforcement in `pipeline-gate.sh`, and keep feature-SHA, HTML, risk, alignment, merge, and archive gates coordinator-owned in the orchestrating skill. Extend the templates and adoption tests so future plugin copies cannot silently regress the contract.

**Tech Stack:** Bash, Markdown skill/templates, static HTML board template, shell contract tests.

---

## Task Dependencies

| Task | Parallel Group | Depends On | Files Touched |
|------|---------------|------------|---------------|
| 1: Contract tests | A | -- | `orchestrator/codex-tests/test-pipeline-gate.sh`, `tests/test-codex-adoption.sh` |
| 2: Worker evidence gate | B | Task 1 | `orchestrator/codex-scripts/pipeline-gate.sh`, `orchestrator/codex-templates/report.md`, `orchestrator/codex-templates/brief.md` |
| 3: Coordinator risk and HTML gates | B | Task 1 | `orchestrator/skills/orchestrating/SKILL.md`, `orchestrator/codex-scripts/alignment-gate.sh`, `orchestrator/codex-tests/test-alignment-gate.sh`, `orchestrator/codex-templates/MISSION.md`, `orchestrator/codex-templates/board.html`, `orchestrator/codex-templates/NEXT-STEPS.md` |
| 4: Validation and publication | C | Tasks 2, 3 | installed plugin copy plus Git metadata |

### Task 1: Add failing workflow contract tests

**Parallel group:** A

**Files:**
- Modify: `orchestrator/codex-tests/test-pipeline-gate.sh`
- Modify: `tests/test-codex-adoption.sh`

**Step 1: Write failing assertions**

Require the report to contain filled `## TDD evidence`, `## Code review`,
`## Verification`, `## Deviations from the brief`, and `## Suggested follow-ups`
sections. Require the skill/templates to name the ordered 10x gates, risk class,
`awaiting-alignment`, durable status/walkthrough HTML, and `NEXT-STEPS.md`.

**Step 2: Run tests to verify RED**

Run `bash orchestrator/codex-tests/test-pipeline-gate.sh` and
`bash tests/test-codex-adoption.sh`.

Expected: FAIL because the new contract is not implemented.

**Commit checkpoint:** tests only — `test: specify orchestrator 10x alignment gates`

### Task 2: Enforce worker-side 10x evidence

**Parallel group:** B

**Files:**
- Modify: `orchestrator/codex-scripts/pipeline-gate.sh`
- Modify: `orchestrator/codex-templates/report.md`
- Modify: `orchestrator/codex-templates/brief.md`

**Step 1: Update the report and brief contracts**

Require the worker to use writing-plans, TDD, requesting-code-review, and
verification-before-completion, recording actual red/green and review evidence.

**Step 2: Update the deterministic gate**

Reject review handoff for missing or placeholder sections without requiring
coordinator-owned post-commit HTML.

**Step 3: Run focused tests to verify GREEN**

Run `bash orchestrator/codex-tests/test-pipeline-gate.sh`.

Expected: all cases pass.

**Commit checkpoint:** worker gate files — `feat: enforce orchestrator worker evidence`

### Task 3: Add coordinator risk, HTML, and next-step merge gates

**Parallel group:** B

**Files:**
- Modify: `orchestrator/skills/orchestrating/SKILL.md`
- Create: `orchestrator/codex-scripts/alignment-gate.sh`
- Create: `orchestrator/codex-tests/test-alignment-gate.sh`
- Modify: `orchestrator/codex-templates/MISSION.md`
- Modify: `orchestrator/codex-templates/board.html`
- Create: `orchestrator/codex-templates/NEXT-STEPS.md`

**Step 1: Record risk and workflow gate state**

Add `routine|material`, the active workflow gate, and `awaiting-alignment` to
mission state. Treat uncertainty as material.

**Step 2: Enforce pre-merge artifacts**

After the broker commit, require status-truth derivation and durable standalone
HTML. For material missions also require change-walkthrough HTML, quiz pass, and
explicit merge approval before integration.

Run a deterministic coordinator gate that validates risk classification,
standalone HTML, broker commit evidence, and material-mission alignment before
merge.

**Step 3: Enforce post-merge truth and follow-ups**

Rerun merged-tree verification, generate final status truth without upgrading
unwitnessed rows, create classified `NEXT-STEPS.md`, link all artifacts on the
board, and only then archive.

Run the coordinator gate again in final mode to reject archive when acceptance,
final truth, or classified next-step artifacts are missing or templated.

**Step 4: Run adoption tests to verify GREEN**

Run `bash tests/test-codex-adoption.sh`.

Expected: PASS.

**Commit checkpoint:** coordinator contract and templates — `feat: add risk-tiered alignment gate`

### Task 4: Validate, synchronize, review, and publish

**Parallel group:** C

**Files:**
- Synchronize: installed orchestrator plugin files
- Publish: repository branch and PR

**Step 1: Run full validation**

Run the skill validator, `git diff --check`, all orchestrator tests, and the
repository adoption contract.

**Step 2: Review the complete diff**

Confirm no sandbox, manifest-authority, or broker boundary is weakened and no
unrelated marketplace-install metadata is staged.

**Step 3: Synchronize the installed plugin**

Copy only the validated orchestrator files and prove relevant source/installed
hashes match.

**Step 4: Publish**

Create a clean branch from current remote `main`, commit only scoped files,
push, and open a draft PR. Because this governance change is material, publish
the pre-merge status truth and change walkthrough, pass the quiz, obtain the
user's explicit merge approval, then mark ready, squash-merge, and verify remote
`main` contains the exact validated blobs.

**Commit checkpoint:** final scoped change — `orchestrator: enforce risk-tiered 10x alignment`
