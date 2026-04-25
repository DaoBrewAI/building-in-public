# design-language-translator

A Claude Code skill that translates plain-language design intent into professional designer vocabulary — bilingual (EN / 中文), and optionally runs an independent design audit when given an image.

## What it does

Founders and engineers describe design through **parameters** ("make it red", "smaller", "more space"). Designers think and communicate through **percepts** ("the value is washed out", "lacks visual hierarchy", "feels uncommitted"). This skill bridges that gap so a designer can actually act on the feedback.

For each piece of input, the skill returns:

- **Translation** — the single best designer-mode phrasing
- **3 alternatives** — diagnostic, prescriptive, and evocative registers
- (Optional) **Image audit** — when an image is attached, 1–3 high-impact issues the user didn't mention

## Language matching

Output language matches input language. The two registers are not direct translations of each other:

- 中文 designer language is more **sensorial / somatic** (大颗粒感的模糊, 沉下去的红, 闷的暖)
- English designer language is more **structural / critical** (washed value, muddy saturation, lacks restraint)

Translation goes into the target language's idiom, not a literal word swap.

## When it triggers

- "translate this for my designer" / "帮我翻译给设计师"
- "我想让设计师..." / vague visual feedback like "make it pop", "this feels off", "我想要禅意的感觉"
- Any aesthetic intent that needs sharpening before it goes to a designer

## Install

1. Download `design-language-translator.skill` from this folder.
2. Drop it into `~/.claude/skills/` or your project's `.claude/skills/`.
3. Restart Claude Code (or reload skills).
