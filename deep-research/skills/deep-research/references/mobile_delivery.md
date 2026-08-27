# Deep Research — Mobile HTML Delivery

## One-file decision

Persist each report as one self-contained HTML document inside its own dated,
descriptively named folder:

```text
explorations/2026-08-09-direction-portfolio/
└── report.html   # canonical report and Graphify source
```

That same file serves two consumers:

- **People:** a responsive interactive page deployed through OpenAI Sites and opened
  from its Sites HTTPS URL on phone or desktop.
- **Graphify:** the `.html` document itself, with a compact structured semantic block
  near the beginning of the raw file.

Do not create a Markdown report copy. Do not add the canonical `report.html` to
`.graphifyignore`. PDF is outside the default Deep Research delivery workflow. Never
update the repository root README or maintain a growing global report index merely to
deliver a report.

A GitHub `blob` or `raw` URL may identify committed source, but it is never the reading
URL because GitHub does not render committed HTML documents as web pages.

Use this delivery order:

1. **OpenAI Sites, owner-only (default):** after the canonical HTML passes Trust Gate,
   HTML validation, and phone viewport checks, deploy it with the available
   `sites:sites-building` and `sites:sites-hosting` skills. Owner-only is the default
   access level and does not require another confirmation after the user asked for a
   Deep Research HTML report.
2. **OpenAI Sites, shared audience (when requested):** selected users, workspace, or
   anyone on the internet requires explicit approval of that exact audience before the
   broader deployment. If the request says only “shareable” without naming an audience,
   ask one concise audience question at publication time. Never infer public access.
3. **Validated local HTML (Sites unavailable):** preserve and return the canonical
   HTML, explain that no Sites HTTPS URL was created, and report the concrete blocker.
   Do not silently substitute another host or a GitHub artifact.
4. **PDF fallback (opt-in only):** generate a derivative PDF only when the user asked
   for it, or after Sites is unavailable and the user explicitly approves PDF fallback.
   It never replaces the canonical HTML or Graphify source.

Official references:

- [OpenAI Sites documentation](https://learn.chatgpt.com/docs/sites)
- [GitHub does not directly render committed HTML documents](https://docs.github.com/en/repositories/working-with-files/using-files/working-with-non-code-files)

## Canonical HTML contract

The beginning of every report must use this order:

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="report-id" content="direction-portfolio-2026-08-09">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; worker-src 'none'; child-src 'none'; object-src 'none'; frame-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'">
  <template id="graphify-source">
# Executive Summary
- Complete key conclusion with its evidence status.

# Conclusions
## Finding 1
- Complete claim, rationale, evidence, and source identifier.
- Recommended next action and owner or decision gate.

# Decision Status
- Exploration only. No confirmed decision was created by this report.

# Sources
- [1] Source title — URL or repository path, accessed YYYY-MM-DD.
  </template>
  <title>Direction Portfolio</title>
  <style>/* all presentation CSS */</style>
</head>
```

Rules:

1. The file contains exactly one `<template id="graphify-source">`.
2. The template appears **after the CSP meta and before the first `<style>`**.
3. The closing `</template>` is within the first 16,000 Unicode characters of the
   file. Graphify 0.8.33 sends at most the first 20,000 characters of each file to
   semantic extraction, so this reserves headroom for surrounding markup.
4. Template content is plain, HTML-escaped, structured Markdown-like text. Do not put
   HTML elements, CSS, SVG, or scripts inside it.
5. It includes the minimum required headings exactly as top-level Markdown headings:
   `# Executive Summary`, `# Conclusions`, `# Decision Status`, and `# Sources`.
   Additional headings are allowed. The authoritative `report-id` is the HTML meta and
   does not need to be duplicated inside the template.
6. It preserves every material conclusion, qualification, evidence label, chart
   takeaway, recommendation, and decision status needed for later retrieval. It is a
   semantic abstract, not merely a table of contents. Keep it compact enough to close
   before character 16,000.
7. Presentation text and the semantic block must not contradict each other. A finding
   visible only in SVG, position, color, tooltip, or a collapsed control must also be
   stated in the semantic block and accessible body text.
8. The footer contains exactly one committed-source placeholder:

   ```html
   <a href="__REPORT_SOURCE_URL__" target="_blank" rel="noopener noreferrer">Committed HTML source</a>
   ```

   When an exact-commit source URL exists, replace the placeholder in the persisted
   canonical HTML before Sites publication. Otherwise replace it with a stable source
   location authorized by the current workflow, or omit the footer link without
   inventing a URL.

The stable report identity is `report_id` + canonical path + source revision when one
exists. The Sites HTTPS URL is the cross-device reading surface; it does not replace the
canonical HTML or its Graphify identity.

## Graphify retrieval gate

HTML is the default and preferred Graphify source. For every finalized report:

1. Confirm `.html` is supported by the installed Graphify version.
2. Confirm neither a broad rule nor a targeted rule in `.graphifyignore` excludes the
   report. Never add `*.html`, `*.reader.html`, or the canonical path as a preventive
   measure.
3. Run the repository's normal Graphify update/extract process.
4. Confirm the manifest names the canonical HTML as a document.
5. Run a report-specific retrieval question, for example:

   ```bash
   graphify query "For report direction-portfolio-2026-08-09, what are the main findings, recommendations, and decision status?"
   ```

6. Treat the smoke test as passing only when the answer identifies the correct report,
   returns the key findings and decision status, and attributes them to the canonical
   `.html` path. Record the tested query and result in the work log or delivery note.

Do not infer failure merely because the HTML contains CSS or SVG. Create a fallback only
after this real retrieval test fails and one retry after correcting the semantic block
also fails.

### Centralized fallback after a proven failure

If the retry still fails, generate one derived Markdown file in a separate centralized
tree that mirrors the HTML path:

```text
canonical:      explorations/2026-08-09-direction-portfolio/report.html
fallback only:  graph-sources/explorations/2026-08-09-direction-portfolio/report.md
```

Never put fallback Markdown beside the HTML. Begin it with generated-source metadata:

```yaml
---
type: graphify-fallback
report_id: direction-portfolio-2026-08-09
canonical_html: explorations/2026-08-09-direction-portfolio/report.html
generated_from_commit: <immutable-commit>
---
```

Copy the semantic template content exactly below that metadata. Then add a **targeted,
root-relative** ignore rule for only the failed canonical HTML, such as:

```gitignore
# Graphify 0.8.33 retrieval failed twice; generated fallback is indexed instead.
/explorations/2026-08-09-direction-portfolio/report.html
```

Re-run Graphify and the same query. The fallback is accepted only if retrieval now
passes. Update or remove the fallback whenever the canonical HTML changes. This mode
avoids duplicate graph nodes while keeping repository clutter out of `explorations/`.

Confirmed decisions remain separate project records only when repository policy
requires them and a human explicitly confirms the decision. An exploration's
`Decision Status` must never silently promote a scenario or recommendation to a fact.

## Publish through OpenAI Sites

Every Sites deployment is a production deployment. Publish only the report that passed
the current run's Trust Gate and mobile acceptance checks.

1. Use `sites:sites-building` to create or update a Sites project from the canonical
   HTML. Preserve the report content, citations, evidence labels, report ID, and
   accessible semantic equivalents. Do not turn the report into an unrelated app or
   add claims during adaptation.
2. Validate the Sites project with its required build and diagnostic checks.
3. Use `sites:sites-hosting` to deploy owner-only by default. Do not ask for another
   confirmation for this private deployment; the user's request for the HTML report is
   sufficient authorization for the default reading surface.
4. If selected-user, workspace, or public access was explicitly requested and approved,
   deploy at that exact access level. Otherwise remain owner-only.
5. Open the deployed Sites HTTPS URL. Verify the visible report, citations, interactive
   controls, and overflow at desktop plus 390 × 844 and 430 × 932 CSS-pixel viewports.
6. Never claim publication from a local build, preview, or deployment command alone.
   The HTTPS URL must load successfully. Return it first in the final handoff.

If Sites deployment fails, preserve the canonical HTML and report the actual failure.
Retry a transient failure once when safe. Do not broaden access, switch providers,
publish through GitHub Actions, or generate a PDF without the corresponding user
authorization.

## Mobile HTML acceptance contract

Before publishing, verify all of the following:

- One `.html` file contains all presentation assets. No external stylesheet, script,
  font, image, iframe, or media dependency is needed to render it. External citation
  links are allowed.
- The exact restrictive CSP shown above is present before the semantic template and
  every style. Runtime networking, scripts, analytics, forms, frames, and external
  assets are blocked.
- External links use `rel="noopener noreferrer"`. Raw research content is escaped or
  allowlist-sanitized before HTML generation. No event-handler attributes are present.
- UTF-8 and the responsive viewport are declared.
- At 390 × 844 and 430 × 932 CSS pixels,
  `document.documentElement.scrollWidth <= window.innerWidth`.
- Body text is at least 16 CSS pixels on phones with comfortable line height. Content
  collapses to one column; wide tables scroll only inside labeled wrappers.
- Tap and keyboard controls work, primary targets are at least 44 × 44 CSS pixels or
  equivalently spaced, and no important information is hover-only.
- Internal anchors exist and IDs are unique. Light and dark themes are legible. Status
  is not conveyed by color alone. Non-essential motion respects reduced motion.
- The semantic block closes before character 16,000 and the Graphify retrieval smoke
  test passes from the canonical HTML, or the documented centralized fallback is used.

## Repository example

Default successful HTML indexing:

```text
DaoBrewStrategy/
├── README.md                                      # unchanged by report delivery
├── explorations/
│   └── 2026-08-09-direction-portfolio/
│       └── report.html                            # canonical + indexed
└── decisions/
    └── DEC-2026-08-10-direction-portfolio.md      # only if explicitly confirmed
```

Only after a proven Graphify failure:

```text
DaoBrewStrategy/
├── explorations/
│   └── 2026-08-09-direction-portfolio/
│       └── report.html
├── graph-sources/
│   └── explorations/
│       └── 2026-08-09-direction-portfolio/
│           └── report.md
└── .graphifyignore   # targets only the failed HTML path
```

The final delivery message is intentionally simple:

```text
Read interactive report — OpenAI Sites HTTPS URL, owner-only
Committed source — exact-commit HTML link when persistence was authorized
Graphify smoke test — PASS for <tested query>
```

Never present the HTML `blob`, `raw`, local, or preview URL as the published reading
link. The final cross-device handoff uses the verified Sites HTTPS URL.
