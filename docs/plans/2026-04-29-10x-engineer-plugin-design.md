# 10x-Engineer Plugin — Design Document

## Goal

Add the 10x-engineer plugin to the `building-in-public` repo as a DaoBrew-branded engineering workflow toolkit, with all Meta-specific or privacy-violating content removed.

## Outcome

No Meta-specific content was found in the plugin. The work is primarily packaging, rebranding, and documentation.

## Decisions

### 1. Structure: Hybrid

One `10x-engineer/` folder at the repo root preserving the full plugin internals (skills, commands, agents, hooks), styled to match the repo's presentation conventions.

Users can install the full plugin at once, or cherry-pick individual skills.

### 2. Attribution: DaoBrew Rebrand with Upstream Credit

Plugin rebranded as "DaoBrew's curated engineering workflow toolkit." Upstream credit to obra/superpowers by Jesse Vincent preserved in `plugin.json` under a `credits` field and in the README.

### 3. Session Hook: Keep As-Is

The `session-start.sh` hook that injects `using-superpowers` into every conversation is preserved. It's the glue that makes Claude check for applicable skills automatically.

### 4. Top-Level README: New "Plugins" Section

A new "Plugins" section added between the Skills table and "Using a skill" instructions. One table row for the 10x-engineer plugin. Brief explanation distinguishing plugins (multi-skill systems) from skills (single-purpose).

### 5. Subfolder README: Guide Style

The `10x-engineer/README.md` includes:
- One-liner positioning
- Workflow diagram showing how skills chain together
- Dual installation instructions (full plugin vs. individual skills)
- Skills catalog grouped by phase (Design, Execution, Quality, Review, Completion, Meta)
- Commands reference
- Credits section

### 6. Auto-Execute Option in Writing Plans

The `writing-plans` skill gets an upfront question at the start:
1. Review the plan before execution (pause for feedback) — current behavior
2. Auto-execute when the plan is ready (start implementing immediately)

If auto-execute is chosen, the execution approach (subagent/team/parallel) is also asked upfront so the user sets both preferences at the start.

The plan document is still saved to disk regardless of mode.

## Files to Create/Modify

| File | Action |
|------|--------|
| `10x-engineer/README.md` | CREATE — guide-style documentation |
| `10x-engineer/.claude-plugin/plugin.json` | MODIFY — rebrand |
| `10x-engineer/skills/writing-plans/SKILL.md` | MODIFY — add auto-execute option |
| `README.md` (top-level) | MODIFY — add Plugins section |
| All other 18 files | COPY verbatim |
