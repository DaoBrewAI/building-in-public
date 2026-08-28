---
name: orchestrator-mediation
description: Triage a mission session's BLOCKED report - answer it, decide it, or escalate it to the user. Used by the orchestrating skill whenever a mission's state file reads "blocked".
---

# Mediating a Blocked Mission Session

Read the newest `BLOCKED-<n>.md` in the mission directory. It contains: what the mission session was doing, the question, 2–3 options with trade-offs, and the session's recommendation. Triage in this order:

## (-1) False least-scope privacy gate — auto-resolve

When a BLOCKED report asks the user to reauthorize already-covered
`auto-least-scope` Fable/Opus inputs, resolve it without asking the user. Check
the Orchestrator invocation and exact durable user decisions, then cite the
standing scope. Treat a claimed security or platform approval gate as real only
when the current turn contains a concrete tool or host denial; model reasoning,
generic caution, a new chat, or reauthentication is not proof. Write the
standing authorization into `ANSWER-<n>.md` and resume the exact recorded Fable
stage. Never create a new consent question merely because the mission moved
from planning to review or resumed the same external session.

## (0) Brainstorm clarification — preserve user intent

When the file contains `kind: brainstorm-clarification`, first check whether the
current request or an exact durable user ruling already answers it. If yes, cite
that answer. Otherwise relay exactly one question with Fable's 2–3 options and
recommendation, then wait for the user. This is product-intent discovery: never
route it through reversible implementation detail or silently choose an option
for the user. Keep the relay concise and return the answer to the same Fable
session through the coordinator's brainstorm-resume path.

## (a) Answerable — answer it yourself

The answer already exists in: the design doc, DECISIONS.md (has this been ruled before? check first — never re-escalate a settled question), the mission's brief, or the codebase (go read the code if that settles it).

→ Write `ANSWER-<n>.md` with the answer and a one-line source reference.

## (b) Reversible implementation detail — decide it yourself

Naming, internal structure, library choice among equivalents, test organization, anything a later refactor can undo cheaply. Default to the session's recommendation unless you see a concrete problem with it.

→ Decide, write `ANSWER-<n>.md` with a one-line rationale.

## (c) Escalate — only for these four

**Scope** (adds/removes what gets built) · **user-visible behavior** · **cost** (money, model spend, infra) · **data** (schema, migration, deletion, privacy).

→ Ask the user with a three-line summary and put the session's recommendation
first as the default. Relay the ruling into `ANSWER-<n>.md`.

## Always, regardless of branch

1. Append the ruling to DECISIONS.md: `## D-<HOST>-<seq> (<mission-slug>, <date>) — <question> / <answer> / decided-by: orchestrator|user`, where `<HOST>` is this machine's existing short host tag and `<seq>` counts only entries carrying that tag. Never mint, renumber, or reuse another host's tag.
2. Keep ANSWER files short: the decision, the rationale in one or two lines, and any concrete values the mission session needs. No essays.
3. If the same mission blocks 3+ times on questions the brief should have answered, the brief was too thin — note it in DECISIONS.md and write richer digests for remaining missions.

## Anti-patterns

- Forwarding the session's BLOCKED file to the user verbatim. Triage first; most blocks are (a) or (b).
- Answering with "use your judgment." If judgment sufficed, the session wouldn't have blocked. Give a concrete ruling.
- Re-litigating a DECISIONS.md entry because a different mission session asked the same thing — cite the D-number and move on.
