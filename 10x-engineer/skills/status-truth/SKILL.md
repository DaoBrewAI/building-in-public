---
name: status-truth
description: Use before publishing any outward-facing status, demo, or buy-in doc a human will ACT on (merge, deploy, report up), and after finishing a code review or development branch when about to claim work is "done" — produces a verified HTML status doc where every claim carries two derived markers (code-state × evidence) so "code merged" is never passed off as "witnessed working."
---

# Status Truth — Two-Axis Verified Status Docs

## Why this exists

A status/buy-in doc collapsed two different truths into one green "shipped" checkmark:
code that was only *merged on a branch* was rendered identically to code *witnessed running
on the reader's machine*. The reader acted on the doc, opened the app, and the claims didn't
match. The running binary was 21 minutes older than the commit being claimed.

**The rule this skill enforces:** every claim carries **two markers, both always shown**, and
the word **"shipped" is banned as a single word**.

- **Axis A — Code state:** `authored` (on a branch) → `merged` (target/main) → `built@<sha>`
  (compiled into the artifact the reader actually runs).
- **Axis B — Evidence:** `tests-green` (raw automated counts) → `witnessed-live` (observed
  executing on the real machine, **with an attached artifact**).

**Invariant (non-negotiable):** a chip may show `witnessed-live` ONLY IF the running build's
SHA is a descendant of the commit that introduced the behavior. Otherwise it **auto-downgrades
to `stale-build`** (amber), regardless of any screenshot. Green means *seen running here*.

## When to invoke

- BEFORE publishing a status / demo / buy-in / release-readiness doc someone will act on.
- AFTER `/code-review`, `requesting-code-review`, or `finishing-a-development-branch`, when you
  are about to assert features are "done."
- The trigger question: **"Am I asking someone to believe this is done?"** If yes, use this skill.

Do NOT use it for internal working notes, commit messages, or in-thread progress updates —
over-applying it turns every sentence into a courtroom.

## The process

Announce: "I'm using the status-truth skill to produce a verified status doc."

### Step 1 — Enumerate claims, attach a feature-SHA to each
List every thing you want to assert. Each MUST name the commit that introduced the behavior.
**No SHA ⇒ it is not a claim** — render it in a separate "Planned / not yet built" group, never
as a status row. This alone kills vague "we did X."

### Step 2 — Establish the running build SHA
Determine what the reader actually runs:
- Signed/CI artifact: read the stamped provenance key (e.g. `DaobrewBuildSHA` in Info.plist,
  a `/version` endpoint, a `BUILD_SHA` env, a git describe baked at build).
- Local/dev build with no stamp: fall back to **binary mtime vs commit timestamps** and say so
  explicitly in the doc (it's weaker evidence — label it).
If you cannot establish a running SHA at all, every row's evidence is capped at `not witnessed`.

### Step 3 — Run the derivation (do not hand-author pills)
Run `scripts/status-provenance.mjs` (in this skill dir) with the feature-SHAs and the running
SHA. It emits, per row: the code-state marker and whether it's `stale-build`. Paste its raw
output into your reasoning; the script — not your judgment — decides the pills.

```
node <skill>/scripts/status-provenance.mjs \
  --repo /path/to/repo --running <running_sha> \
  --claims '[{"id":"D·E","label":"Connections tidied","sha":"0048f1e","tests":"10/10"}, ...]'
```

### Step 4 — Gate `witnessed-live` on an artifact
A row is green ONLY with an artifact record: `{type: screenshot|log|probe, path_or_quote,
captured_against_sha, timestamp}` where `captured_against_sha == running_sha`. No artifact ⇒
the row stays blue (`merged · not witnessed`) or amber (`stale-build`). You may mark a row green
from your OWN observation only if you captured the artifact against the running build; a subagent
"tests passed" report is `tests-green`, never `witnessed-live`.

### Step 5 — Render the HTML (use the template)
Build from `assets/status-template.html` (in this skill dir). It encodes the color law so you
cannot render an unwitnessed row green. Use the `visualize:visualize` skill when
available; otherwise save a self-contained, CSP-safe HTML file and provide its path.

### Step 6 — Pre-publish assertion (say this back to the human)
Before publishing any doc with green rows, state one line:
> "N rows green (each witnessed on build `<sha8>`); M rows blue/amber — <reasons>."

Publishing a green row without a passing derivation + artifact is the one forbidden act.

## Color law (baked into the template — do not override)

- **Green** iff `built ⊇ feature` AND `witnessed-live` (artifact present, SHA matches).
- **Amber** for any `stale-build` — reason inline: `running <sha8> · feature landed <sha8>`.
- **Blue** for `merged · tests-green · not witnessed` (legitimate "done in code, unseen live").
- **Grey/hollow** for `authored` only or no evidence.
- **Auto footer:** "N of M witnessed live on build `<sha8>`; K merged-but-unwitnessed."

## Red flags (you are rationalizing — stop)

| Thought | Reality |
|---|---|
| "The code's on the branch, so it's shipped." | Branch ≠ the reader's running build. Derive it. |
| "The agent said 28/28 tests, mark it done." | That's `tests-green`, not `witnessed-live`. |
| "I read the source; the UI collapses." | Reading ≠ witnessing. No artifact ⇒ not green. |
| "It's basically working, green is fine." | The template refuses. Provide the artifact or stay blue. |
| "Rebuild is trivial, I'll assume it's built." | The 21-minute gap is exactly this assumption. Check the SHA. |

## Integration

- **Called after:** `10x-engineer:requesting-code-review`, `10x-engineer:finishing-a-development-branch`.
- **Uses:** `visualize:visualize` when available, or a local self-contained HTML file.
- **Never green without:** a running-SHA-matched artifact.
