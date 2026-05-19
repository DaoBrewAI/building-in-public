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

## Report Structure

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

### Step 1: Generate markdown report file

```bash
# Create report with timestamp
cat > "/tmp/research_report_$(date +%s).md" << 'EOF'
[Your complete markdown report following the structure above]
EOF
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
