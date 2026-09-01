# building-in-public

> Public agent workflow systems from **DaoBrew AI** — Codex skills, Claude Code skills, and build-loop tools we use while building body-aware task infrastructure.

Each guide, skill, or plugin lives in its own folder with a short README. Codex skills install as folders under `~/.codex/skills`; Claude Code packages may also include a self-contained `.skill` bundle.

---

## 🎮 Interactive Builds

| Build | What it is | Try it |
| :--- | :--- | :--- |
| ⚔️ &nbsp;[**DaoBrew Causal Raid**](./causal-raid) | DaoBrew can feel abstract, so this one-minute browser raid makes its causal task loop easier to understand by turning it into something you can play. More importantly, it is fun. | [**Play now →**](https://daobrewai.github.io/building-in-public/causal-raid/) |

---

## 🛠️ Skills

| Skill | What it does |
| :--- | :--- |
| 🗣️ &nbsp;[**renhua（人话）**](./renhua) | 中文 AI/技术写作去 AI 味：保留作者的判断、事实、技术细节和亲身经验，去掉模板化结构与讲义腔。 |
| 🎬 &nbsp;[**daobrew-video**](./daobrew-video) | DaoBrew's HyperFrames video house style: script-derived captions, founder-safe overlays, brand templates, and the standard amber outro. |
| 🧭 &nbsp;[**finding-your-unknowns**](./finding-your-unknowns) | Codex-native skill for surfacing hidden task unknowns before implementation: Goal frame, ranked hypotheses, decisive discriminators, down-ranked blindspots, scaled Unknowns Maps, and `codex-loop-engineering` handoff integration. |
| 🔁 &nbsp;[**codex-loop-engineering**](./codex-loop-engineering) | Codex skill and installer for repo-local goal/tracker/constraints/handoff loops, checkpoint verification, and verified auto-chain continuation sessions. |
| 🎨 &nbsp;[**design-language-translator**](./design-language-translator) | Translates plain-language design intent (EN / 中文) into professional designer vocabulary. With an image attached, also runs an independent design audit and flags 1–3 high-impact issues you didn't mention. |
| ☯️ &nbsp;[**bazi-reader**](./bazi-reader) | Generates a personalized Bazi (八字) reading from a birth datetime. Useful for reading the energy around a specific date — e.g. the Meta 5/20 layoff window — or as a reference layer for long-horizon planning like fundraising and key launches. |
| 📬 &nbsp;[**inbox-baseline-audit**](./inbox-baseline-audit) | First-meeting skill for AI delivery teams: connect a customer's last 30/60 days of Gmail + Drive, produce three verifiable fact cards + a workflow catch + a baseline draft, and run a three-act demo that ends with a signed baseline — not applause. Validated on a real inbox before publishing. |
<!-- Add new skills above this line. Format: | emoji [**name**](./folder) | one-line description | -->

---

## Guides

| Guide | What it covers |
| :--- | :--- |
| [**codex-loop-engineering**](./codex-loop-engineering) | Codex loop engineering operating guide and loop-file installer. |

<!-- Add new guides above this line. Format: | [**name**](./folder) | one-line description | -->

---

## 🔌 Plugins

Plugins are multi-skill systems — install the whole folder for the full workflow, or cherry-pick individual skills. See each plugin's README for details.

| Plugin | What it does |
| :--- | :--- |
| 🧠 &nbsp;[**10x-engineer**](./10x-engineer) | Dual-host Codex/Claude workflow toolkit with 15 skills for brainstorming, planning, TDD, debugging, agent-driven development, review, verification, and evidence-backed handoff. |
| 🎛️ &nbsp;[**orchestrator**](./orchestrator) | Codex/Claude mission control: guarded worktrees, one resumable autonomous session per mission, blocker mediation, verified acceptance, and disk-first recovery. |
| 📋 &nbsp;[**project-planner**](./project-planner) | Multi-phase project planning and execution framework. Break down large projects into phases, generate detailed plans, track status, and execute task-by-task with build verification and checkpoints. |

<!-- Add new plugins above this line. Format: | emoji [**name**](./folder) | one-line description | -->

Install the Codex-native plugins from this repository:

```bash
codex plugin marketplace add DaoBrewAI/building-in-public --ref main
codex plugin add 10x-engineer@building-in-public
codex plugin add orchestrator@building-in-public
```

Start a new Codex task after installation so the bundled skills are discovered.

---

## 📌 On the bazi-reader

> **Not a prediction tool.** It does not forecast layoffs, illness, financial outcomes, or any specific life event.

What it *does*: analyze the **energetic profile** of a date or month against a personal chart — favorable / unfavorable tendencies, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Like a weather forecast before a long hike — not to decide whether the hike is "destined" to succeed, but to inform what to pack. The same applies to longer-horizon planning (fundraising windows, launch timing, key hires): a second lens on the energetic backdrop, **alongside** — never instead of — the actual analysis you'd normally do.

---

## 🚀 Using a skill

### Codex skills

For Codex folder skills such as `finding-your-unknowns` or `codex-loop-engineering`:

```bash
cd /path/to/building-in-public/finding-your-unknowns
bash install-codex-skill.sh
```

Restart or reload Codex, then invoke it by name:

```text
Use $finding-your-unknowns to map the unknowns before implementing this task.
```

### Claude Code `.skill` files

1. Open the skill's folder and download its `.skill` file.
2. Drop it into your Claude Code skills directory:
   ```
   ~/.claude/skills/      # global
   .claude/skills/        # per-project
   ```
3. Restart Claude Code (or reload skills).

The skill activates automatically when its trigger phrases appear in conversation. Each skill folder has a README with the full trigger list and any extra setup.

---

## 🌿 About DaoBrew

DaoBrew AI is building body-aware task infrastructure for agentic work. We open-source the workflow tooling that makes the work possible — these skills are part of that.

---

## 🔗 Related: DaoBrew Wellness MCP

We also maintain an open-source MCP server for TCM-grounded wellness tooling:

### → [github.com/DaoBrewAI/daobrew-wellness-mcp](https://github.com/DaoBrewAI/daobrew-wellness-mcp)

The MCP server exposes DaoBrew's wellness primitives — TCM constitution analysis, classical-framework-grounded diet and lifestyle guidance, biometric-aware recommendations — as **tools any MCP-compatible client can call** (Claude Desktop, Claude Code, Cursor, etc.).

The split between the two repos:

- **Skills (this repo)** → *workflow*. How an agent works through a task.
- **MCP server** → *domain knowledge*. What an agent knows and can look up.

If you're building anything in the health / wellness space and want an opinionated TCM layer, start there.
