# building-in-public

This is the repo for **DaoBrew AI** — building in public.

We share the Claude Code skills we use internally to develop DaoBrew. Each skill is a self-contained `.skill` file you can drop into your own Claude Code setup.

## Skills

| Skill | Description |
|---|---|
| [design-language-translator](./design-language-translator.skill) | Translates plain-language design intent (EN/中文) into professional designer vocabulary. When given an image, also runs an independent design audit and flags 1–3 high-impact issues the user didn't mention. |
| [bazi-reader](./bazi-reader.skill) | Generates a personalized Bazi (八字 / Chinese Four Pillars) reading from a birth datetime. Useful for gathering perspective on a specific month or date — e.g., the Meta 5/20 layoff window — by analyzing the energetic interaction between your chart and that day's pillar. Also handy as a reference layer for long-term strategy planning around fundraising, launches, hiring, or other key events. |

<!-- Add new skills above this line. Format: | [name](./name.skill) | one-line description | -->

## A note on the bazi-reader

This skill is **not a prediction tool**. It does not forecast layoffs, illness, financial outcomes, or any specific life event. What it does is analyze the energetic profile of a date or month against a personal chart — favorable / unfavorable tendencies, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Use it the way you'd use a weather forecast before a long hike: not to decide whether the hike is "destined" to succeed, but to inform what to pack. The same applies to longer-horizon planning — fundraising windows, product launch timing, key hiring decisions — where a second lens on the energetic backdrop can be useful alongside (never instead of) the actual analysis you'd normally do.

## Using a skill

1. Download the `.skill` file from this repo.
2. Drop it into your Claude Code skills directory (`~/.claude/skills/` or your project's `.claude/skills/`).
3. Restart Claude Code or reload skills. The skill activates automatically when its trigger phrases appear in conversation.

## About DaoBrew

DaoBrew AI is building agentic tools at the intersection of TCM (Traditional Chinese Medicine) and modern AI. Follow along here as we open-source the tooling that makes the work possible.
