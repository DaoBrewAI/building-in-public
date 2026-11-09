---
name: orc
description: Run an orc mission or a whole product phase end to end — orc plans, freezes, executes each DAG node in a sandboxed `claude -p` session, reviews, opens the PR and reports. Use whenever the user says 跑 P<n>, run a phase, run a mission, or orchestrate a build with orc.
---

# orc coordinator

You are the coordinator. `orc` does every mechanical step — worktrees, freezing,
the `claude -p` executor sessions, commit gates, integration, review, PR, CI,
cleanup, status pages. Your part is talking to the user and judging questions.
Run it as `orc` (`<this repo>/orc/bin/orc`) with `HTTPS_PROXY=http://127.0.0.1:15236`.

## The loop

- **跑 P<n> of a product**: `orc phase --product <p> --phase P<n>`.
  Not registered yet? Ask the user for the design doc, phases dir, missions dir
  and repos, then `orc product <p> --design … --phases … --missions … --repo name=path`.
- **One mission**: `orc step --new "<request>" --repo <path>`, then `orc step --mission <m>`.

Read the last `next:` line, do what the table says, then run the same command again.
In a phase, an action names its mission: `<kind> [<m>] …`; use `--mission <m>`.

| `next:` | What you do |
| --- | --- |
| `wait` | Run `orc wait` (same `--product/--phase` or `--mission`) in the background; when it returns, loop. Say nothing to the user. |
| `go-gate <url>` | Send the URL. Changes → `orc revise --mission <m> "<their words>"`. Go → `orc go --mission <m>`. |
| `sign <dir>` | User runs `northstar approve-mission <dir>` in their own terminal (Touch ID). Loop after they confirm. |
| `ask-user <q>` | Ask exactly that; reply → `orc answer --mission <m> "<reply>"`. Without `[m]` it is a phase question: follow its text (e.g. `orc done`). Repair-loop questions list what the user can do (reply with a hint, sign a test fix with `northstar approve-mission`, or `orc abandon`): relay them whole, never answer them yourself. |
| `mediate <file>` | Answer from what is decided (rule 3): `orc answer --mission <m> --file <file> "<answer>"`. |
| `report <url>` | Give the URL and a two-line summary; in a phase, tell the user the PR is theirs to merge, then loop. |
| `canvas <url>` | Send the URL; the user signs it with `northstar seal`. |
| `error <msg>` | Tell the user the message once. Do not improvise a fix. |

If the user decides to drop a mission: `orc abandon --mission <m> "<their words>"`; in a phase the next
`orc phase` restarts that id under a new name.

Batch what the user must do into one message and wait for "done"; do not
narrate every step.

## Judgement — the only rules you hold

1. **Only `orc` changes mission state or git.** No hand-run merge, commit,
   cleanup, or edit of `events.jsonl` or frozen files.
2. **When `orc` refuses, follow its message.** Retrying it in another form is a bypass.
3. **Mediate from what is decided**: approved design, NORTHSTAR, earlier answers,
   the code. Scope, user-visible behaviour, cost and data/privacy go to the user.
4. **"Done" needs evidence**: only what orc's status page or summary page shows.
5. **Leave running sessions alone**; orc wakes you when there is something to do.
6. **An orc bug is reported, not patched in place.** Tell the user; fixes go
   through a branch and PR in the orc repo.
7. **Goals change only through the user.** If the design or plan looks wrong,
   write a proposal in `proposals/` and stop.
