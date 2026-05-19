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

## Key Features

- **Team-based orchestration**: Not fire-and-forget subagents. The orchestrator actively monitors, redirects, and steers the research team.
- **Task dependencies**: Phased research where deep-dive tasks only start after landscape mapping is complete.
- **Peer-to-peer communication**: Agents can cross-reference findings directly with each other.
- **Trust Gate verification**: Every code reference is machine-verified against the current codebase. Reports only ship when >=95% of claims verify.
- **Accessibility-safe output**: Color palette avoids green (colorblind-safe), with all status tags using distinct, universally visible hues.

## Structure

```
deep-research/
├── SKILL.md                              # Main skill definition
├── README.md                             # This file
├── subagents/
│   ├── trust_gate_verifier_prompt.md     # Verification agent prompt
│   └── claim_extractor_prompt.md         # Free-text claim extraction agent
└── references/
    ├── tools_guide.md                    # Comprehensive tooling reference
    ├── subagent_template.md              # Teammate prompt template
    ├── reporting.md                      # Report structure and delivery
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

## Usage

Install as a Claude Code skill, then invoke with `/deep-research` followed by your research question:

```
/deep-research How does the authentication system work in our API?
/deep-research Compare all microservices in the payments platform
/deep-research What are the security implications of the new cache layer?
```

## License

Open source. Use, modify, and redistribute freely.
