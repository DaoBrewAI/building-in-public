# Deep Research — Synthesis & Reporting

## Table of Contents

- [Information Integration](#information-integration)
- [Report Structure](#report-structure)
- [Delivering the Report](#delivering-the-report)
  - [Step 1: Generate the canonical HTML](#step-1-generate-the-canonical-html)
  - [Step 2: Publish a mobile reading URL](#step-2-publish-a-mobile-reading-url)
  - [Step 3: Verify Graphify retrieval](#step-3-verify-graphify-retrieval)
  - [Step 4: Confirm delivery](#step-4-confirm-delivery)
- [Resource Budgets](#resource-budgets)

## Information Integration

After all tasks are complete (or enough data collected):
1. Identify consensus findings across multiple agents
2. Note any conflicts or discrepancies
3. Prioritize based on source quality and recency
4. Cross-reference with documentation

## Report Format (MANDATORY)

1. **Deliver one canonical mobile-first HTML report.** The self-contained HTML (inline
   presentation assets; light and dark themes via CSS custom properties and
   `prefers-color-scheme`) is both the durable Git source and the human reading surface.
   Embed the complete key semantics in a compact Markdown-like template near the start
   so Graphify can index this same file directly. A committed GitHub `blob` or `raw` URL
   is the source location, not the reading URL; for a private repository, publish the
   report as a direct, unarchived Actions artifact. Do not generate a sibling Markdown
   file unless the real Graphify retrieval gate fails. Follow
   [mobile_delivery.md](mobile_delivery.md).
2. **PDF is an explicit fallback, not a default deliverable.** Generate it only when
   the user asks for a PDF or when the verified HTML reading route cannot be published.
   The HTML remains canonical and Graphify-indexed; the PDF is a derivative for
   offline/download use. Preserve the HTML rendering (headless-Chrome print, forced
   light theme, `<details>` opened, print CSS) and keep all external and internal links
   working.
   **Use the ready pipeline: `references/scripts/html_report_to_pdf.py`** (SRC_HTML /
   PDF_ZOOM env vars; adjust GROUPS + NEEDLES per report — see its header comments).
   When PDF fallback is required, the tuned recipe is:
   - Chrome print crashes on large SVG-heavy documents → print in chunks, merge with
     pypdf; every chunk boundary forces a page break (a potential half-empty page), so
     make chunk groups as large as printing succeeds, splitting only the failing group.
   - Desktop density: `zoom: 0.82` + tightened margins/section spacing — at 1.0,
     unbreakable figures jump pages and leave large blanks.
   - Chrome silently drops `#anchor` links whose target isn't in the printed chunk →
     pre-rewrite internal hrefs to `https://anchor.internal/<id>`, then rewrite those
     URI annotations into GoTo destinations after merging, locating targets by
     NFKC-normalized text markers (Chrome maps some CJK glyphs to Kangxi radicals).
   - Keep the PDF under ~10MB or GitHub won't render it inline: chunked printing
     duplicates font subsets → pypdf `compress_identical_objects` +
     `compress_content_streams` after merging.
   The script asserts: zero sentinel URIs, internal GoTo count == internal href count,
   external URI count matches, size <10MB; spot-render a page before delivery.

3. **Diagrams first, prose second.** Wherever a finding can be shown as a picture, show
   it as a picture: comparisons → bar/quadrant charts, structures → block diagrams,
   flows/decisions → flow diagrams, timelines → timelines, confidence distributions →
   stacked bars (inline SVG preferred). Prose is for what a diagram cannot carry.
   A reader should get the argument by scanning the figures and captions alone.
4. **Evidence chain is visible.** Every external claim carries a numbered citation
   superscript, color-coded by confidence tier (primary-verified / cross-verified /
   partially-confirmed / estimate-only / unverifiable / contradicted-corrected), linking
   to a numbered reference table with source-type tags and access dates.
   **Dedupe references by CONTENT, not URL**: the same article syndicated or mirrored
   on multiple platforms (TechCrunch↔Yahoo Finance, journal↔PubMed Central, press
   release↔wire repost, original↔translation) is ONE source under ONE reference number —
   fold mirror URLs into that entry as labeled mirrors. Never let a mirror appear as a
   second independent source supporting the same claim; independence requires distinct
   authorship/reporting. Translations/derivatives may be listed only when they serve a
   distinct evidentiary role, explicitly labeled non-independent.
5. **Derivation transparency for internal numbers.** Any number NOT backed by an
   external source (internal estimate, assumption, self-set target, illustrative curve)
   must be visibly tagged as such **in the figure itself** (e.g. a dashed "internal
   estimate" badge or inline label), not only in surrounding text, AND accompanied by a
   note showing HOW it was derived (inputs × assumptions, e.g. "population × pay-rate ×
   price assumption"). If the derivation cannot be shown, either drop the number or
   explicitly mark it "derivation not preserved — do not quote externally". Conceptual
   illustrations must be labeled "illustrative, not measured data".
6. **Figure/text alignment.** Figures and prose must carry the SAME epistemic markings.
   A figure may never present as fact a number that the text qualifies as estimate or
   inference (and vice versa) — after any verification pass, re-sweep every figure
   (including SVG text and aria-labels) so in-figure wording matches the verified
   conclusions. The bar for the whole report: a reader can tell, for every number,
   where it came from and whether to trust it.

## Report Structure

Place this compact semantic outline inside the HTML's unique
`<template id="graphify-source">`. Its closing tag must be within the first 16,000
characters so Graphify 0.8.33 receives it inside the 20,000-character raw cap:

```markdown
# Executive Summary
- Key findings in 3-5 bullet points
- Critical context

# Conclusions

## [Perspective/Component 1]
- Finding with evidence (file_path:line_number references)
- Context (team, platform, history)

## [Perspective/Component 2]
...

# Decision Status
- Confirmed / exploration only, with explicit rationale

# Sources
- Primary: [Specific files, commits, build targets]
- Secondary: [Related documentation, queries]
```

These four top-level headings are the validation minimum. Put recommendations under
`# Conclusions` or add an extra heading; extra structure must never become a reason to
reject an otherwise complete semantic block.

## Delivering the Report

After synthesizing the research findings:

### Step 1: Generate the canonical HTML

Generate one self-contained `.html` report containing inline CSS, inline SVG diagrams,
confidence-colored citation superscripts, the numbered reference table, and the
structured semantic template required by [mobile_delivery.md](mobile_delivery.md). Put
that one file in the repository when the report is project state; use `/tmp` only for
drafts or when the user asked for local-only artifacts. Do not generate or persist a
PDF unless Report Format rule 2 applies.

Do not leave unique conclusions inside SVG text or interactive controls. Preserve a
text equivalent in accessible body content and the semantic template. Add the report
ID, strict CSP, and `__REPORT_SOURCE_URL__` placeholder required by the workflow.

Validate the file against the mobile HTML acceptance contract in
[mobile_delivery.md](mobile_delivery.md), including real rendering at 390 × 844 and
430 × 932 CSS pixels.

### Step 2: Publish a mobile reading URL

Choose the least-public delivery method that meets the user's request:

- **Private GitHub repository (default):** use the workflow in
  `templates/private-html-preview.yml` to publish a non-zipped, directly viewable HTML
  artifact. Run the workflow definition from the default branch and pass the exact
  pushed report commit as `source_ref`. For a GitHub Free private repository, keep the
  workflow's `archive: false` direct artifact. Return the completed run/artifact URL,
  not the `blob` URL; `blob` and `raw` always identify source bytes.
- **Stable private URL:** with explicit authorization, use an identity-protected static
  site as described in `mobile_delivery.md`.
- **Local-only delivery:** return the absolute HTML file path and state that it is not
  yet reachable from the user's phone.

Do not upload to a paste service or public Pages site unless the user explicitly
authorizes public disclosure.

After the artifact succeeds and opens, publish the repository navigation required by
`mobile_delivery.md`: add the vertical `📱 阅读网页` block to the root README and the
report-directory README, and record the immutable source commit and timezone-qualified
expiry timestamp. Add only newly created navigation-only directory READMEs to
`.graphifyignore`; keep an existing semantic root README indexed. Then commit and push
the focused navigation update. When the artifact expires, rerun it from the same
immutable source commit and commit/push the refreshed URL and expiry in both entries.

### Step 3: Verify Graphify retrieval

Keep the canonical HTML indexable, run the repository's normal Graphify update, and ask
a report-specific question covering its main findings, recommendations, and decision
status. Use the HTML alone when retrieval succeeds. Only after a real failure and one
semantic-template correction/retry may you create the centralized
`graph-sources/<same-relative-path>.md` fallback described in
[mobile_delivery.md](mobile_delivery.md). Never put fallback Markdown beside the report.

### Step 4: Confirm delivery

- Inform the user that the full report has been generated
- Put the clickable interactive HTML URL first; a local path alone is not a mobile
  handoff
- Include the exact-commit canonical HTML source link and Graphify smoke-test result
- State whether the link requires GitHub sign-in and when it expires
- Confirm that both navigation README entries and every required exact
  navigation-only `.graphifyignore` rule were committed and pushed
- Provide a brief summary (2-3 sentences) in the response

## Resource Budgets

Enforce limits to prevent system overload:
- **Simple queries**: 20 tool calls per task
- **Medium complexity**: 40 tool calls per task
- **High complexity**: 60 tool calls per task (hard limit: 80)
- **Result limits**: always use limit flags (e.g., `--max-count 80`)
