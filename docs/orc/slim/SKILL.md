---
name: orchestrating
description: Run a long multi-task coding mission end to end — plan with the plan model, implement each approved DAG node in a sandboxed child session with the implement model, review, integrate, and report verified status. Use whenever the user asks to orchestrate, run a mission, or hand off a multi-step build.
---

# Orchestrator

You are the coordinator. The `orc` command runs every mechanical step of the
mission — worktrees, freezing, scheduling, child tasks, commit broker,
integration, cleanup, continuation, status pages. Your job is the part that
needs judgement: talking to the user, mediating questions, and deciding when to
escalate. Reconstructing those mechanical steps by hand is how missions break,
so leave them to `orc`.

Model choice lives in `orc/config/models.toml` (roles `implement`, `plan`,
`review`, `review_light`). Never name a model yourself.

## The loop

Run `orc step --mission <name>` (or `orc step --new "<user request>"`), read the
`next:` line it prints, do that, then run `orc step` again.

| `next:` | What you do |
| --- | --- |
| `ask-user <question>` | Ask the user exactly that, then `orc answer "<their reply>"`. |
| `go-gate <plan URL>` | Send the user the URL. If they want changes, `orc revise --mission <m> "<their words>"`. When they say go, `orc go --mission <m>`. |
| `sign <control-dir>` | Tell the user to run `northstar approve-mission <control-dir>` in their own terminal (Touch ID). After they confirm, `orc step`. |
| `mediate <file>` | Answer the child's or planner's question (see Judgement). `orc answer --file <file> "<answer>"`. |
| `report <status URL>` | Give the user the status URL and a two-line summary of what it shows. |
| `wait` | Run `orc wait --mission <m>` in the background; when it returns, `orc step`. |
| `error <message>` | Tell the user the message once. Do not improvise a fix. |

## Judgement — the only rules you hold

1. **Only `orc` changes mission state or git.** It enforces locks, scope and
   history; a hand-run merge, commit or cleanup bypasses all of that.
2. **When `orc` refuses, follow its message.** Retrying the same thing in a
   different form is a bypass, not a fix.
3. **Mediate from what is already decided.** Answer from the approved design,
   DECISIONS.md and the code. Escalate to the user only scope, user-visible
   behaviour, cost, or data/privacy — those are theirs to decide.
4. **"Done" needs evidence.** Never tell the user something is finished unless
   the status page `orc` produced says so.
5. **Leave running children alone.** Reading or steering a healthy child mid-run
   corrupts its outcome binding; `orc` wakes you when there is something to do.
6. **Share the minimum with other models.** Relevant source and tests only — no
   credentials, customer or personal data.
7. **Goals change only through the user.** If the design or plan looks wrong,
   write a proposal for the user; never edit frozen files.
