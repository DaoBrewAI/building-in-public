# 🎨 design-language-translator

> A Claude Code skill that translates plain-language design intent into the vocabulary a designer can actually act on. Bilingual (EN / 中文). Image-aware.

---

## The problem it solves

Founders and engineers describe design through **parameters** — *"make it red", "smaller", "more space."*

Designers think and communicate through **percepts** — *"the value is washed out", "lacks visual hierarchy", "feels uncommitted."*

This skill bridges the gap so feedback lands on a designer as something they can act on, not something they have to translate first.

---

## What you get back

For each piece of input:

- **Translation** — the single best designer-mode phrasing
- **3 alternatives** — diagnostic, prescriptive, and evocative registers
- **Image audit** *(when an image is attached)* — 1–3 high-impact issues you didn't mention

---

## 🌐 Language matching

Output language matches input language. The two registers are **not direct translations** of each other:

| Register | Flavor | Examples |
| :--- | :--- | :--- |
| 中文 designer | sensorial / somatic | 大颗粒感的模糊 · 沉下去的红 · 闷的暖 |
| English designer | structural / critical | washed value · muddy saturation · lacks restraint |

The skill translates *into the target language's idiom*, not literally word-for-word.

---

## When it triggers

- *"translate this for my designer"* / *"帮我翻译给设计师"*
- *"我想让设计师..."*
- Vague visual feedback: *"make it pop"*, *"this feels off"*, *"我想要禅意的感觉"*
- Any aesthetic intent that needs sharpening before it goes to a designer

---

## 📦 Install

1. Download `design-language-translator.skill` from this folder.
2. Drop it into `~/.claude/skills/` (or `.claude/skills/` for per-project).
3. Restart Claude Code (or reload skills).
