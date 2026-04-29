# building-in-public

> The repo for **DaoBrew AI** — sharing the Claude Code skills we use internally to build at the intersection of TCM and modern AI.

Each skill lives in its own folder with a self-contained `.skill` file and a short README. Drop one into your Claude Code setup and it activates on its trigger phrases.

---

## 🛠️ Skills

| Skill | What it does |
| :--- | :--- |
| 🎨 &nbsp;[**design-language-translator**](./design-language-translator) | Translates plain-language design intent (EN / 中文) into professional designer vocabulary. With an image attached, also runs an independent design audit and flags 1–3 high-impact issues you didn't mention. |
| ☯️ &nbsp;[**bazi-reader**](./bazi-reader) | Generates a personalized Bazi (八字) reading from a birth datetime. Useful for reading the energy around a specific date — e.g. the Meta 5/20 layoff window — or as a reference layer for long-horizon planning like fundraising and key launches. |

<!-- Add new skills above this line. Format: | emoji [**name**](./folder) | one-line description | -->

---

## 🔌 Plugins

Plugins are multi-skill systems — install the whole folder for the full workflow, or cherry-pick individual skills. See each plugin's README for details.

| Plugin | What it does |
| :--- | :--- |
| 🧠 &nbsp;[**10x-engineer**](./10x-engineer) | A complete engineering workflow toolkit — brainstorming, planning, TDD, debugging, code review, and subagent-driven development. Twelve skills that chain together to take you from idea to merged PR. |

<!-- Add new plugins above this line. Format: | emoji [**name**](./folder) | one-line description | -->

---

## 📌 On the bazi-reader

> **Not a prediction tool.** It does not forecast layoffs, illness, financial outcomes, or any specific life event.

What it *does*: analyze the **energetic profile** of a date or month against a personal chart — favorable / unfavorable tendencies, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Like a weather forecast before a long hike — not to decide whether the hike is "destined" to succeed, but to inform what to pack. The same applies to longer-horizon planning (fundraising windows, launch timing, key hires): a second lens on the energetic backdrop, **alongside** — never instead of — the actual analysis you'd normally do.

---

## 🚀 Using a skill

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

DaoBrew AI is building agentic tools at the intersection of **TCM (Traditional Chinese Medicine)** and modern AI. We open-source the tooling that makes the work possible — these skills are part of that.

---

## 🔗 Related: DaoBrew Wellness MCP

We also maintain an open-source MCP server for TCM-grounded wellness tooling:

### → [github.com/DaoBrewAI/daobrew-wellness-mcp](https://github.com/DaoBrewAI/daobrew-wellness-mcp)

The MCP server exposes DaoBrew's wellness primitives — TCM constitution analysis, classical-framework-grounded diet and lifestyle guidance, biometric-aware recommendations — as **tools any MCP-compatible client can call** (Claude Desktop, Claude Code, Cursor, etc.).

The split between the two repos:

- **Skills (this repo)** → *workflow*. How an agent works through a task.
- **MCP server** → *domain knowledge*. What an agent knows and can look up.

If you're building anything in the health / wellness space and want an opinionated TCM layer, start there.
