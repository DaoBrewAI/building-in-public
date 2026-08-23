# Canonical mobile HTML report example

This fixture contains exactly one persisted report: `example-report.html`.

The file is simultaneously:

- the responsive human reading surface;
- the canonical Git source; and
- the default Graphify document.

Its unique `graphify-source` template appears immediately after the restrictive CSP and
before presentation CSS. The template closes within the first 16,000 characters and
contains the report's complete key semantics in structured Markdown-like text.

Run the repository's Graphify update and a report-specific retrieval query against the
HTML first. Do not exclude this file in `.graphifyignore`. Only after a real retrieval
failure plus one corrected retry may a derived fallback be created at the centralized
path `graph-sources/deep-research/examples/mobile-html-report/example-report.md`; in
that exceptional mode, ignore only this exact HTML path to prevent duplicate nodes.

The private GitHub workflow validates the security and semantic contract, then replaces
`__REPORT_SOURCE_URL__` in a temporary upload copy with the exact-commit URL for this
same HTML file.
