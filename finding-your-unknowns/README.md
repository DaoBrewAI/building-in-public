# finding-your-unknowns

> A Claude Code skill that helps an agent surface hidden task unknowns before they become expensive implementation guesses.

Inspired by Thariq Shihipar's X article: ["A Field Guide to Fable: Finding Your Unknowns"](https://x.com/trq212/status/2073100352921215386?s=46).

---

## The idea

The prompt, skills, and context you give an agent are the **map**. The real codebase, constraints, user taste, data model, and hidden coupling are the **territory**.

Many coding-agent failures happen when the agent hits an unknown mid-build and silently guesses. This skill makes the agent surface the unknowns early, classify them, and resolve the important ones with the cheapest possible move.

The four buckets:

| Bucket | Meaning | Move |
| :--- | :--- | :--- |
| Known knowns | Facts already stated or visible in the repo | Keep explicit |
| Known unknowns | Questions the user knows are open | Ask focused questions |
| Unknown knowns | Taste / intuition the user can recognize but not specify cold | Show options |
| Unknown unknowns | Hidden constraints nobody considered | Repo-grounded blindspot pass |

---

## What the skill does

It starts by anchoring the **Goal frame**: what the final good thing looks like, what evidence would prove it works, and what is out of scope.

Then it scales the workflow:

- **Trivial edits**: skip the skill entirely.
- **Medium diagnostics / read-only investigations**: compact report only:
  - Goal frame
  - up to 3 ranked hypotheses
  - one decisive discriminator per hypothesis
  - down-ranked blindspots
  - deferred questions if the user cannot answer live
- **Large builds**: full Unknowns Map, resolving moves, plan, implementation notes, explainer / quiz, and possible fresh-session handoff.

The goal is not "more process." The goal is fewer wrong turns.

---

## Trial result

The first trial found the right root cause but was too ceremonial: it produced a full Unknowns Map and extra tables for a medium debugging task.

After revision, the skill was re-tested on the same style of ambiguous report:

> "the CTO's memory pipeline won't connect to the reasoner"

The revised skill stayed in medium diagnostic mode. It produced:

- a Goal frame with acceptance evidence,
- 3 ranked hypotheses,
- decisive discriminators,
- blindspots explicitly down-ranked as likely-by-design / roadmap / architecture risk,
- deferred questions instead of blocking on `AskUserQuestion`.

Score moved from roughly **6.8 / 10** after the first trial to **8.4 / 10** after the Goal-aware revision. Remaining cost: the agent may still read deeply, but the final output shape is now much tighter.

---

## Install

1. Download `finding-your-unknowns.skill` from this folder.
2. Drop it into:

```text
~/.claude/skills/      # global
.claude/skills/        # per-project
```

3. Restart Claude Code or reload skills.

You can also copy the expanded folder directly if you want to inspect or edit the skill source.

---

## When it triggers

- Ambiguous bug report
- Unfamiliar repo or module
- Architecture / data-model / API decision
- UX or taste-heavy implementation
- Long-horizon multi-file build
- Any task where "what good looks like" is not yet crisp

It should **not** trigger for trivial, well-specified edits.
