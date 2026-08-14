---
name: orchestrator-mediation
description: Triage a mission session's BLOCKED report - answer it, decide it, or escalate it to the user. Used by the orchestrating skill whenever a mission's state file reads "blocked".
---

# Mediating a Blocked Mission Session

A block can come from either stage backend — the planner/reviewer (claude) or the executor (codex). Triage is identical; only the resume differs: check the last `stage:` line in the mission's `session.txt` and pass `--stage exec` to spawn-worker.sh when it says exec.

Read the newest `BLOCKED-<n>.md` in the mission directory. It contains: what the mission session was doing, the question, 2–3 options with trade-offs, and the session's recommendation. Triage in this order:

## (a) Answerable — answer it yourself

The answer already exists in: the design doc, DECISIONS.md (has this been ruled before? check first — never re-escalate a settled question), the mission's brief, or the codebase (go read the code if that settles it).

→ Write `ANSWER-<n>.md` with the answer and a one-line source reference.

## (b) Reversible implementation detail — decide it yourself

Naming, internal structure, library choice among equivalents, test organization, anything a later refactor can undo cheaply. Default to the session's recommendation unless you see a concrete problem with it.

→ Decide, write `ANSWER-<n>.md` with a one-line rationale.

## (c) Escalate — only for these four

**Scope** (adds/removes what gets built) · **user-visible behavior** · **cost** (money, model spend, infra) · **data** (schema, migration, deletion, privacy).

→ Ask the user with a 3-line summary + the session's recommendation as the default option (AskUserQuestion style, recommendation first). Relay their ruling into `ANSWER-<n>.md`.

## Always, regardless of branch

1. Append the ruling to DECISIONS.md: `## D-<HOST>-<seq> (<mission-slug>, <date>) — <question> / <answer> / decided-by: orchestrator|user`, where `<HOST>` is this machine's short host tag (see the numbering rule in `orchestrating`) and `<seq>` counts only entries carrying that same tag. Never renumber or reuse another host's tag.
2. Keep ANSWER files short: the decision, the rationale in one or two lines, and any concrete values the mission session needs. No essays.
3. If the same mission blocks 3+ times on questions the brief should have answered, the brief was too thin — note it in DECISIONS.md and write richer digests for remaining missions.

## Anti-patterns

- Forwarding the session's BLOCKED file to the user verbatim. Triage first; most blocks are (a) or (b).
- Answering with "use your judgment." If judgment sufficed, the session wouldn't have blocked. Give a concrete ruling.
- Re-litigating a DECISIONS.md entry because a different mission session asked the same thing — cite the D-number and move on.
