# project-planner

> DaoBrew's multi-phase project planning and execution framework for Claude Code. Break down large projects into phases, generate detailed plans, track status, and execute everything task-by-task — with build verification and checkpoints at every step.

---

## How It Works

The plugin manages the full lifecycle of a multi-phase project:

```
Master Plan (design doc)
    │
    ├── /plan-phase 1      → docs/plans/phase1-*.md
    ├── /plan-phase 2      → docs/plans/phase2-*.md
    │   ... or ...
    └── /plan-all-phases   → all phase plans at once
                │
                ├── /plan-status         → dashboard of what's done
                │
                ├── /implement-phase 1   → execute phase 1 tasks
                ├── /implement-phase 2   → execute phase 2 tasks
                │   ... or ...
                └── /implement-project   → execute all phases end-to-end
```

**Plan Phase** reads your master plan and generates a detailed, task-level implementation plan for a single phase — with exact code, parallel groups, build verification, and commit steps. **Plan All Phases** does this for every remaining phase in batch, properly chaining dependencies between them.

**Plan Status** shows a dashboard of all phases — which have plans, which are implemented, which are in progress, and what command to run next.

**Implement Phase** executes a phase plan task-by-task with build verification after each task, parallel execution for independent tasks, and automatic deviation tracking. **Implement Project** orchestrates all phases sequentially with user checkpoints between each.

---

## Installation

### Full Plugin (recommended)

Copy the `project-planner/` folder into your Claude Code plugins directory:

```bash
cp -r project-planner/ ~/.claude/plugins/local/project-planner/
```

### Individual Skills

Cherry-pick specific skills:

```bash
cp -r project-planner/skills/plan-phase/ ~/.claude/skills/plan-phase/
cp -r project-planner/skills/plan-status/ ~/.claude/skills/plan-status/
```

---

## Skills

| Skill | What it does | Dependencies |
| :--- | :--- | :--- |
| **plan-phase** | Generate a detailed implementation plan for a single project phase from a master plan | Standalone |
| **plan-all-phases** | Generate plans for all remaining phases in batch with proper dependency chaining | plan-phase |
| **plan-status** | Show a dashboard of all phases with status, implementation progress, and next actions | Standalone |
| **implement-phase** | Execute a phase plan task-by-task with build verification and parallel execution | 10x-engineer:executing-plans |
| **implement-project** | Execute all phases sequentially with user checkpoints between each phase | implement-phase, 10x-engineer:executing-plans |

---

## Dependencies

Requires the [10x-engineer](../10x-engineer) plugin (for the `executing-plans` skill used during implementation).

---

## Plan File Conventions

- Plans are stored in `docs/plans/`
- Naming: `YYYY-MM-DD-phase<N>-descriptive-slug.md`
- Phase index: `docs/plans/PHASE-INDEX.md`

---

## Credits

Created by [DaoBrew AI](https://github.com/DaoBrewAI). MIT licensed.
