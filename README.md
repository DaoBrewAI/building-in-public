# building-in-public

This is the repo for **DaoBrew AI** — building in public.

We share the Claude Code skills we use internally to develop DaoBrew. Each skill is a self-contained `.skill` file you can drop into your own Claude Code setup.

## Skills

| Skill | Description |
|---|---|
| [design-language-translator](./design-language-translator.skill) | Translates plain-language design intent (EN/中文) into professional designer vocabulary. When given an image, also runs an independent design audit and flags 1–3 high-impact issues the user didn't mention. |

<!-- Add new skills above this line. Format: | [name](./name.skill) | one-line description | -->

## Using a skill

1. Download the `.skill` file from this repo.
2. Drop it into your Claude Code skills directory (`~/.claude/skills/` or your project's `.claude/skills/`).
3. Restart Claude Code or reload skills. The skill activates automatically when its trigger phrases appear in conversation.

## About DaoBrew

DaoBrew AI is building agentic tools at the intersection of TCM (Traditional Chinese Medicine) and modern AI. Follow along here as we open-source the tooling that makes the work possible.
