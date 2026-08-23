# Deep Research — Mobile HTML Delivery

## One-file decision

Persist each report as one self-contained HTML document inside its own dated,
descriptively named folder:

```text
explorations/2026-08-09-direction-portfolio/
├── README.md     # navigation card only; not report content
└── report.html   # canonical report and Graphify source
```

That same file serves two consumers:

- **People:** a responsive interactive page opened from a private GitHub Actions
  artifact link on phone or desktop.
- **Graphify:** the `.html` document itself, with a compact structured semantic block
  near the beginning of the raw file.

Do not create a Markdown report copy. The folder `README.md` is only the GitHub-rendered
link panel needed to open the Reader; it must not repeat conclusions or evidence and is
excluded from Graphify. Do not add the canonical `report.html` to `.graphifyignore`.
PDF is outside the default deep-research delivery workflow. Never update the repository
root README or maintain a growing global report index for report delivery.

A GitHub `blob` or `raw` URL is the committed source location, not the reading URL:
GitHub does not render committed HTML documents as web pages.

> **PAUSED (Linhan 2026-08-23):** the Actions-artifact channel is suspended to stop
> GitHub Actions budget consumption. Do not install or dispatch
> `private-html-preview.yml`. Interim phone-readable link: the committed companion
> PDF's blob URL (GitHub renders <10MB PDFs inline, including in the mobile app).

Use this delivery order:

1. **Companion PDF blob URL (interim default while the Actions channel is paused):**
   commit the PDF beside the canonical HTML and hand out its GitHub blob URL. Requires
   GitHub sign-in and repository read access; renders inline on phone; no retention
   expiry.
2. **Private GitHub artifact (PAUSED):** publish the single HTML file as an
   unarchived Actions artifact (`archive: false`). When active, this is the default
   reading surface for a GitHub Free private repository; it requires GitHub sign-in
   and repository read access and remains subject to artifact retention.
3. **Stable private site (only when requested):** deploy the same file to an
   identity-protected static host. Creating a project, domain, access policy, or
   deployment requires explicit authorization.
4. **Local-only:** return the absolute HTML path and say clearly that it is not yet a
   phone-accessible URL.

Official references:

- [GitHub does not directly render committed HTML documents](https://docs.github.com/en/repositories/working-with-files/using-files/working-with-non-code-files)
- [Direct, non-zipped GitHub Actions artifacts](https://github.blog/changelog/2026-02-26-github-actions-now-supports-uploading-and-downloading-non-zipped-artifacts/)
- [`actions/upload-artifact` direct-file mode](https://github.com/actions/upload-artifact/blob/main/README.md)
- [GitHub artifact access and retention](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)

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

   The workflow replaces it only in the temporary artifact copy with the exact-commit
   GitHub `blob` URL for this same HTML file.

The stable report identity is `report_id` + repository path + Git commit. An artifact
URL is a replaceable reading envelope and may expire without changing the report or
Graphify source.

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

## Install the private preview once

Copy `templates/private-html-preview.yml` into the target repository as:

```text
.github/workflows/private-html-preview.yml
```

The workflow must be present on the default branch. It accepts one repository-relative
`.html` path and publishes it with the SHA-pinned `actions/upload-artifact` action using
`archive: false`. This direct-file mode is why CSS, SVG, icons, and images must all be
inline. Private reports use native HTML interactions rather than JavaScript.

## Publish a report

After the canonical HTML is committed and pushed:

1. Open **Actions → Private HTML Report → Run workflow** on the default branch.
2. Set `source_ref` to the immutable report commit when possible.
3. Set `report_path` to the canonical file, for example
   `explorations/2026-08-09-direction-portfolio/report.html`.
4. Open the completed job summary and tap **Open the interactive HTML report**.
5. Verify that URL at a phone-sized viewport and share it only with collaborators who
   already have repository read access.

Authorized agents may dispatch it with:

```bash
gh workflow run private-html-preview.yml \
  --ref '<default-branch-containing-workflow>' \
  -f source_ref='<immutable-report-commit>' \
  -f report_path='explorations/2026-08-09-direction-portfolio/report.html'
```

`--ref` selects the workflow definition; `source_ref` selects the historical report
content. Re-run the default-branch workflow with the same commit and path to replace an
expired artifact link. Never claim publication until the run succeeds and the artifact
opens in a browser.

## Publish the report-folder link card after artifact success

Treat the report-folder link card as part of default private-report delivery, not an
optional follow-up. Perform it only after the workflow succeeds, the artifact opens,
and the job summary provides the expected expiry timestamp. Do not add the report to
the repository root README, the parent collection README, or a global report index.

1. Capture the direct artifact URL, the full immutable `source_ref` commit that contains
   the canonical HTML, the exact HTML source URL, and the expiry timestamp from the
   successful run. Display the timestamp with an explicit timezone, preferably UTC.
2. Create or replace the `README.md` inside this report's own folder. It is a tiny
   GitHub-rendered navigation card, not a second report. It must contain no report
   summary, conclusions, evidence, or decision text. Never modify the repository root
   README as part of report delivery.
3. Use a vertical block, never a Markdown table. Keep the artifact link first:

   ```markdown
   ### <report title>

   **[📱 阅读网页（推荐）](<direct-artifact-url>)**

   Source: [`<report-path>`](<exact-commit-blob-url>)

   Immutable source commit: [`<full-sha>`](<commit-url>)

   Expires: `YYYY-MM-DD HH:MM UTC`

   Requires GitHub sign-in and read access to this private repository. If the link has
   expired, rerun `Private HTML Report` with the same source commit and report path,
   then replace this URL and expiry date.
   ```

4. Keep these navigation cards out of Graphify with one sustainable, parent-scoped
   rule. Before adding it, verify that every matched immediate child is a report folder
   and that no semantic README is captured. For an `explorations/` report collection:

   ```gitignore
   /explorations/*/README.md
   ```

   Never add the canonical report HTML to `.graphifyignore` unless the separately
   documented two-failure Graphify fallback gate has actually fired.
5. Review the folder-card diff, then create and push a focused handoff commit containing
   only this report's README and any one-time `.graphifyignore` contract change.
   Keep the displayed immutable source commit pinned to the earlier report commit; the
   navigation commit is not a replacement source identity.

GitHub `blob` and `raw` URLs always identify source bytes; they are never the reading
surface. The `archive: false` Actions artifact is the directly viewable mobile surface
for the default GitHub Free private-repository path.

When an artifact expires, rerun the default-branch workflow with the same immutable
`source_ref` and `report_path`. After the replacement artifact opens, update the URL and
expiry date only in that report folder's README and commit/push that focused refresh.
Do not change the source commit unless the report content itself changed.

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
├── .graphifyignore                                # /explorations/*/README.md
├── explorations/
│   └── 2026-08-09-direction-portfolio/
│       ├── README.md                              # link card only; ignored
│       └── report.html                            # canonical + indexed
├── decisions/
│   └── DEC-2026-08-10-direction-portfolio.md   # only if explicitly confirmed
└── .github/workflows/
    └── private-html-preview.yml
```

Only after a proven Graphify failure:

```text
DaoBrewStrategy/
├── explorations/
│   └── 2026-08-09-direction-portfolio/
│       ├── README.md
│       └── report.html
├── graph-sources/
│   └── explorations/
│       └── 2026-08-09-direction-portfolio/
│           └── report.md
└── .graphifyignore   # targets only the failed HTML path
```

The final delivery message is intentionally simple:

```text
Read interactive report — private GitHub artifact link, expires YYYY-MM-DD HH:MM UTC
Committed source — exact-commit HTML link, indexed by Graphify
Repository navigation — report-folder README link committed and pushed; root unchanged
Graphify smoke test — PASS for <tested query>
```

Never present the HTML `blob` URL as the reading link.

## Stable private reading URL

When a bookmarkable non-expiring URL is explicitly requested, use an
identity-protected static host such as Cloudflare Pages Direct Upload plus Cloudflare
Access. Upload only the rendered report; do not grant a hosting service access to the
whole private repository unless the user chooses that integration. Verify while signed
out that authentication appears before report content. Do not assume ordinary GitHub
Pages is private merely because its source repository is private.
