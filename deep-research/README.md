# Deep Research

A multi-agent research orchestration skill for Claude Code that enables systematic, team-based deep research across large codebases.

## What It Does

Deep Research coordinates a team of AI agents to investigate complex questions about your codebase. Instead of a single agent doing sequential research, it:

1. **Classifies** your query (depth-first, breadth-first, or straightforward)
2. **Reconnoiters** the landscape before committing to a research plan
3. **Spawns a coordinated team** of specialized agents working in parallel
4. **Orchestrates actively** — cross-pollinating findings, redirecting agents, creating follow-up tasks
5. **Verifies claims** via an automated Trust Gate that catches hallucinated references
6. **Synthesizes** findings into a structured, evidence-backed report
7. **Delivers one canonical HTML report**: the same self-contained file is the
   interactive reading surface and the default Graphify source

## Key Features

- **Team-based orchestration**: Not fire-and-forget subagents. The orchestrator actively monitors, redirects, and steers the research team.
- **Task dependencies**: Phased research where deep-dive tasks only start after landscape mapping is complete.
- **Peer-to-peer communication**: Agents can cross-reference findings directly with each other.
- **Trust Gate verification**: Every code reference is machine-verified against the current codebase. Reports only ship when >=95% of claims verify.
- **Accessibility-safe output**: Color palette avoids green (colorblind-safe), with all status tags using distinct, universally visible hues.
- **Graph-safe phone delivery**: A compact Markdown-like semantic block is embedded near
  the start of the responsive HTML, so Graphify can retrieve the report without adding
  a sibling file. The HTML is published as a private, directly viewable GitHub Actions
  artifact instead of a source-code `blob`.

## Structure

```
deep-research/
├── SKILL.md                              # Main skill definition
├── README.md                             # This file
├── templates/
│   └── private-html-preview.yml          # Private GitHub mobile HTML preview
├── examples/
│   └── mobile-html-report/                # Canonical single-HTML fixture
├── subagents/
│   ├── trust_gate_verifier_prompt.md     # Verification agent prompt
│   └── claim_extractor_prompt.md         # Free-text claim extraction agent
└── references/
    ├── tools_guide.md                    # Comprehensive tooling reference
    ├── subagent_template.md              # Teammate prompt template
    ├── reporting.md                      # Report structure and delivery
    ├── mobile_delivery.md                # HTML hosting + Graphify contract
    ├── orchestration_example.md          # End-to-end example + anti-patterns
    ├── finding_schema.md                 # Structured Finding JSON schema
    ├── color_palette.md                  # Accessibility-safe color palette
    └── scripts/
        ├── trust_gate.sh                 # Trust Gate decision engine
        ├── render_footnotes.py           # Footnote renderer
        ├── symbol_in_code.py             # Code vs comment/string detection
        ├── symbol_patterns.sh            # Language-aware symbol patterns
        ├── finding_template.sh           # Finding JSON skeleton emitter
        └── lint_rule.sh                  # Lint dispatcher (accessibility)
```

## Adapting for Your Environment

This skill was designed to be tool-agnostic. The `references/tools_guide.md` uses generic examples (ripgrep, git, etc.) that you can adapt to your specific tools:

| Concern | Adapt to your... |
|---------|-----------------|
| Code search | ripgrep, grep, ag, or your org's code search tool |
| Version control | git, hg, sl, or your VCS |
| Build system | Bazel, Buck2, CMake, Gradle, etc. |
| Code review | GitHub PRs, GitLab MRs, Phabricator, Gerrit, etc. |
| Documentation | Confluence, Notion, wiki, or your knowledge base |
| SQL/Data | Your SQL engine (Presto, BigQuery, Snowflake, etc.) |

## Prerequisites

- Claude Code with team/task support
- `jq` (for Trust Gate script)
- `ripgrep` (optional, for symbol verification — falls back to grep)
- Python 3 (for footnote rendering and symbol detection)
- Optional: GitHub Actions with `actions/upload-artifact@v7` for private mobile HTML
  previews

## Usage

Install as a Claude Code skill, then invoke with `/deep-research` followed by your research question:

```
/deep-research How does the authentication system work in our API?
/deep-research Compare all microservices in the payments platform
/deep-research What are the security implications of the new cache layer?
```

The completed result is one canonical `.html` file plus a private, phone-readable
interactive link. Graphify indexes the HTML directly. A centralized Markdown fallback
under `graph-sources/` is created only after an actual retrieval smoke test proves that
the HTML failed; it is never stored beside the report. PDF is not part of the default
report workflow.

## License

Open source. Use, modify, and redistribute freely.
