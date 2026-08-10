# Deep Research — Synthesis & Reporting

## Table of Contents

- [Information Integration](#information-integration)
- [Report Structure](#report-structure)
- [Delivering the Report](#delivering-the-report)
  - [Step 1: Generate markdown report file](#step-1-generate-markdown-report-file)
  - [Step 2: Share the report](#step-2-share-the-report)
  - [Step 3: Confirm delivery](#step-3-confirm-delivery)
- [Resource Budgets](#resource-budgets)

## Information Integration

After all tasks are complete (or enough data collected):
1. Identify consensus findings across multiple agents
2. Note any conflicts or discrepancies
3. Prioritize based on source quality and recency
4. Cross-reference with documentation

## Report Format (MANDATORY)

1. **Two deliverables every time: HTML + PDF.** The final output is (a) a single
   self-contained HTML file (inline CSS, no external assets; support both light and dark
   themes via CSS custom properties + `prefers-color-scheme` + `:root[data-theme]`
   overrides) — HTML is required because diagrams and text must render as one integrated
   document — and (b) a PDF render of the same report for mobile/offline reading, since
   raw HTML can't be viewed rendered from a phone (especially via GitHub links).
   PDF requirements: preserve the HTML rendering (headless-Chrome print-to-PDF, forced
   light theme, all `<details>` opened, `@page`/break-inside print CSS); ALL hyperlinks
   must still work — external URLs and internal anchor jumps alike. Known pitfalls and
   the working recipe: Chrome's print pipeline fails on large SVG-heavy documents —
   print top-level sections as separate chunks and merge with pypdf; Chrome silently
   drops `#anchor` links whose target isn't in the printed chunk — pre-rewrite internal
   hrefs to a sentinel absolute URL (e.g. `https://anchor.internal/<id>`), then after
   merging rewrite those URI annotations into GoTo destinations located by text markers
   (normalize extracted text with NFKC — Chrome maps some CJK glyphs to Kangxi radicals).
   Verify before delivery: zero sentinel URIs left, internal GoTo count == internal href
   count in the HTML, external URI count matches, spot-render a page. Keep the PDF under
   ~10MB or GitHub won't render it inline — chunked printing duplicates font subsets, so
   run pypdf `compress_identical_objects` + `compress_content_streams` after merging.
2. **Diagrams first, prose second.** Wherever a finding can be shown as a picture, show
   it as a picture: comparisons → bar/quadrant charts, structures → block diagrams,
   flows/decisions → flow diagrams, timelines → timelines, confidence distributions →
   stacked bars (inline SVG preferred). Prose is for what a diagram cannot carry.
   A reader should get the argument by scanning the figures and captions alone.
3. **Evidence chain is visible.** Every external claim carries a numbered citation
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
4. **Derivation transparency for internal numbers.** Any number NOT backed by an
   external source (internal estimate, assumption, self-set target, illustrative curve)
   must be visibly tagged as such **in the figure itself** (e.g. a dashed "internal
   estimate" badge or inline label), not only in surrounding text, AND accompanied by a
   note showing HOW it was derived (inputs × assumptions, e.g. "population × pay-rate ×
   price assumption"). If the derivation cannot be shown, either drop the number or
   explicitly mark it "derivation not preserved — do not quote externally". Conceptual
   illustrations must be labeled "illustrative, not measured data".
5. **Figure/text alignment.** Figures and prose must carry the SAME epistemic markings.
   A figure may never present as fact a number that the text qualifies as estimate or
   inference (and vice versa) — after any verification pass, re-sweep every figure
   (including SVG text and aria-labels) so in-figure wording matches the verified
   conclusions. The bar for the whole report: a reader can tell, for every number,
   where it came from and whether to trust it.

## Report Structure

The content outline below still applies — render it as the HTML document described above
(the markdown skeleton is the content model, not the delivery format):

```markdown
# Research Report: [Topic]

## Executive Summary
- Key findings in 3-5 bullet points
- Critical context

## Detailed Findings

### [Perspective/Component 1]
- Finding with evidence (file_path:line_number references)
- Context (team, platform, history)

### [Perspective/Component 2]
...

## Recommendations
- Actionable next steps
- Relevant teams/experts to consult
- Related commits/PRs to review

## Sources
- Primary: [Specific files, commits, build targets]
- Secondary: [Related documentation, queries]
```

## Delivering the Report

After synthesizing the research findings:

### Step 1: Generate HTML report file and its PDF render

```bash
# Create report with timestamp (self-contained HTML per "Report Format" above)
cat > "/tmp/research_report_$(date +%s).html" << 'EOF'
[Your complete HTML report: inline CSS, inline-SVG diagrams for every major
finding, confidence-colored citation superscripts + numbered reference table]
EOF

# Then produce the companion PDF per "Report Format" rule 1 (chunked
# headless-Chrome print + pypdf merge + link rebuild). Deliver BOTH files
# together — the HTML is the canonical document, the PDF is the
# mobile/offline render.
```

### Step 2: Share the report

Choose the delivery method appropriate for your environment:

**Option A: Google Docs** (if available)
```bash
# Convert to Google Doc
# Use whatever tool is available in your environment to convert markdown to Google Docs

# Notify the user
echo "Research Complete: [Brief Topic] - Summary of findings. View report: [URL]"
```

**Option B: Direct file sharing**
```bash
# The report is available at the local path
ls -t /tmp/research_report_*.md | head -1
```

**Option C: Paste service** (if available)
```bash
# Upload to your organization's paste service
cat /tmp/research_report_TIMESTAMP.md | <paste-tool>
```

### Step 3: Confirm delivery

- Inform the user that the full report has been generated
- Include the file path and/or URL in your response
- Provide a brief summary (2-3 sentences) in the response

## Resource Budgets

Enforce limits to prevent system overload:
- **Simple queries**: 20 tool calls per task
- **Medium complexity**: 40 tool calls per task
- **High complexity**: 60 tool calls per task (hard limit: 80)
- **Result limits**: always use limit flags (e.g., `--max-count 80`)
