# building-in-public

This is the repo for **DaoBrew AI** — building in public.

We share the Claude Code skills we use internally to develop DaoBrew. Each skill lives in its own folder with a self-contained `.skill` file plus a short README.

## Skills

| Skill | Description |
|---|---|
| [design-language-translator](./design-language-translator) | Translates plain-language design intent (EN / 中文) into professional designer vocabulary. When given an image, also runs an independent design audit and flags 1–3 high-impact issues the user didn't mention. |
| [bazi-reader](./bazi-reader) | Generates a personalized Bazi (八字 / Chinese Four Pillars) reading from a birth datetime. Useful for gathering perspective on a specific month or date — e.g., the Meta 5/20 layoff window — by analyzing the energetic interaction between your chart and that day's pillar. Also handy as a reference layer for long-term strategy planning around fundraising, launches, hiring, or other key events. |

<!-- Add new skills above this line. Format: | [name](./folder) | one-line description | -->

## A note on the bazi-reader

This skill is **not a prediction tool**. It does not forecast layoffs, illness, financial outcomes, or any specific life event. What it does is analyze the energetic profile of a date or month against a personal chart — favorable / unfavorable tendencies, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Use it the way you'd use a weather forecast before a long hike: not to decide whether the hike is "destined" to succeed, but to inform what to pack. The same applies to longer-horizon planning — fundraising windows, product launch timing, key hiring decisions — where a second lens on the energetic backdrop can be useful alongside (never instead of) the actual analysis you'd normally do.

## Using a skill

1. Open the skill's folder and download its `.skill` file.
2. Drop it into your Claude Code skills directory (`~/.claude/skills/` or your project's `.claude/skills/`).
3. Restart Claude Code or reload skills. The skill activates automatically when its trigger phrases appear in conversation.

Each skill folder also has its own README with triggers, install notes, and design principles.

## About DaoBrew

DaoBrew AI is building agentic tools at the intersection of TCM (Traditional Chinese Medicine) and modern AI. Follow along here as we open-source the tooling that makes the work possible.

## Related: DaoBrew Wellness MCP

We also maintain an open-source MCP server for TCM-grounded wellness tooling:

**[github.com/DaoBrewAI/daobrew-wellness-mcp](https://github.com/DaoBrewAI/daobrew-wellness-mcp)**

The MCP server exposes DaoBrew's wellness primitives — TCM constitution analysis, diet / lifestyle guidance grounded in classical frameworks, and biometric-aware recommendations — as tools any MCP-compatible client (Claude Desktop, Claude Code, Cursor, etc.) can call. Skills in this repo are about workflow; the MCP server is about giving any agent direct, structured access to DaoBrew's domain knowledge. If you're building anything in the health / wellness space and want an opinionated TCM layer, start there.
