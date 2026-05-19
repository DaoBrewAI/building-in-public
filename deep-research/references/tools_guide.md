# Tools Comprehensive Guide

This reference provides detailed documentation for development tools commonly used in large-scale codebases, optimized for research teammates.

## Code Search at Scale

### Tool Selection Matrix
| Pattern Type | Tool | Example | Use Case |
|-------------|------|---------|----------|
| Regex | `grep -rE` / `rg` | `rg "class.*Test" --max-count 80` | Pattern matching, wildcards |
| Exact String | `grep -rF` / `rg -F` | `rg -F "exact_function" --max-count 80` | Literal text search |
| Filename | `find` / `fd` | `find . -name "*.py" \| head -80` | File discovery |

### Essential Flags
- `--max-count N` / `-m N` (ripgrep) or `head -N`: Limit results (ALWAYS USE)
- `-g PATTERN` (ripgrep): Filter by file path glob
- `-l`: Show only filenames
- `-C N` or `--context N`: Show N lines of context

### Common Patterns
```bash
# Find Python test files in specific project
find ./src -name "*test*.py" | head -80

# Search for class definitions with context
rg "^class\s+\w+.*:" -C 5 --max-count 80

# Find exact imports
rg -F "from auth.platform import" -l --max-count 50

# Complex regex with file filter
rg -g "src/**/*.py" "def\s+\w+_handler" --max-count 30
```

### Handling Large Search Scopes
When search scope is too broad:
```bash
# Option 1: Narrow the path
rg -g "src/platform/**/*.py" "pattern" --max-count 80

# Option 2: Use VCS file list pipeline
git ls-files | grep "auth.*\.py$" | xargs grep -l "pattern"

# Option 3: Get file list first, then search
FILES=$(git ls-files | grep "pattern")
echo "$FILES" | xargs grep -n "search_term"
```

## Version Control (Git/Mercurial/Sapling)

### Essential Commands
```bash
# Navigation
git log --oneline --graph    # Visualize commit history
git checkout <hash>          # Navigate to commit

# History
git log --stat HEAD~5..HEAD  # Recent commits with file changes
git reflog | head -20        # Recent position changes
git show <hash>              # Full diff of commit

# File Operations
git ls-files                 # All tracked files
git status                   # Modified, added, removed
git diff                     # Unstaged changes

# Diff Analysis
git diff <old>..<new>        # Compare commits
git diff --stat              # Summary of changes
```

### Working with Branches/Stacks
```bash
# View branches
git branch -a

# Navigate
git checkout <branch>

# Understand history
git reflog | head -20
git log --all --oneline --graph
```

## Build System

Adapt these examples to your build system (Bazel, Buck2, CMake, Gradle, etc.):

```bash
# Find target ownership (example: Bazel)
bazel query 'owner("src/auth/handler.py")'

# List targets in BUILD file
bazel query 'targets_in_pkg("//src/auth")'

# Dependency analysis
bazel query 'deps("//src/auth:handler")'
bazel query 'rdeps("//...", "//src/auth:handler")'
```

## Code Review Tool Integration

Adapt these examples to your code review system (GitHub PRs, GitLab MRs, Phabricator, etc.):

```bash
# GitHub example
gh pr view 123                     # View PR details
gh pr diff 123                     # View PR diff
gh pr checks 123                   # View CI status
gh pr list --author user --limit 10

# GitLab example
glab mr view 123
glab mr diff 123

# Phabricator example
# arc diff --preview
# arc list
```

## Knowledge/Documentation Search

Use whatever documentation tools are available in your environment:
- Internal wiki search
- Documentation site search
- Knowledge base APIs
- Confluence, Notion, or similar tools

### Best Practices
1. **Prefer specific over search**
   - If you have a specific document ID → load it directly
   - If you need to discover → use search

2. **Use appropriate filters**
   - Filter by document type to reduce noise
   - Use time filters for recent information

3. **Combine with other tools**
   - Use code search for source code
   - Use doc search for documentation and context
   - Use VCS for history

## SQL / Data Queries

### Query Template
```sql
SELECT column1, column2, COUNT(*) as cnt
FROM schema.table
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY  -- REQUIRED date filter
  AND other_conditions
GROUP BY column1, column2
ORDER BY cnt DESC
LIMIT 100                  -- ALWAYS limit exploration
```

### Common Operations
```sql
-- Schema discovery
DESCRIBE schema.table;
-- or: SHOW COLUMNS FROM schema.table;

-- Sample data
SELECT *
FROM schema.table
WHERE created_at >= CURRENT_DATE - INTERVAL '1' DAY
LIMIT 10;

-- Count by date partition
SELECT DATE(created_at) as dt, COUNT(*) as row_count
FROM schema.table
WHERE created_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY DATE(created_at)
ORDER BY dt DESC;
```

## Performance Optimization Tips

### Search Optimization
1. Always use result limit flags
2. Start with narrow searches, broaden if needed
3. Use file path filters when possible
4. Prefer exact string search over regex when applicable

### Query Optimization
1. Use most specific build query type (owner vs deps)
2. Cache query results when doing multiple operations
3. Batch related queries together

### Pipeline Optimization
1. Use parallel tool calls for independent operations
2. Chain commands efficiently with pipes
3. Exit early when objective is met

## Error Recovery Patterns

### Common Errors and Solutions

| Error | Solution |
|-------|----------|
| "Too many results" | Use narrower path filter or VCS pipeline |
| "Build target not found" | Use query to discover correct target |
| "Permission denied" | Check team ownership, try different approach |
| "SQL timeout" | Add more filters, reduce date range |
| "Commit/PR not found" | Verify ID, check if merged |

### Fallback Chains
```text
Primary → Fallback 1 → Fallback 2
ripgrep → narrower ripgrep → git ls-files | grep
build query → check BUILD file directly
code review CLI → API query → manual investigation
SQL query → smaller date range → sample subset
```

## Tool Limits Reference

| Tool | Limit Type | Value | Workaround |
|------|-----------|-------|------------|
| grep/ripgrep | Results | Use limit flags | Always specify |
| SQL | Query time | ~30 seconds | Add filters |
| Build system | Target depth | Recursive can be slow | Use specific paths |

## Best Practices Summary

1. **Always limit results** - Use --max-count, LIMIT, head -N
2. **Start specific** - Narrow searches, broaden if needed
3. **Use correct tool** - ripgrep for code, doc search for docs
4. **Check ownership** - Build targets own files
5. **Prefer simple** - CLI tools over complex API queries
6. **Document paths** - Use file_path:line_number format
7. **Handle errors** - Have fallback strategies ready
8. **Track budget** - Count tool calls, stop before limit
