# ☯️ bazi-reader

> A Claude Code skill that generates a personalized, playful Bazi (八字 / Chinese Four Pillars) reading from a birth datetime — including how the current monthly pillar (流月) interacts with your chart.

---

## What you get back

Given **year / month / day / hour** of birth:

- **Your chart** — the four pillars + day master
- **You × the current month (流月)** — how this month's pillar interacts with your chart, via Ten God relationships and any branch 冲 / 合
- **Today's energy** — the day pillar of the date being analyzed
- **Working with this week** — concrete *do / don't* items, framed as energy guidance

Pass `--analyze-date YYYY-MM-DD` to point the reading at any specific date (e.g. `2026-05-20`) instead of today.

---

## ⚠️ What it is *not*

> **Not a prediction tool.** Does not forecast layoffs, illness, financial outcomes, or any specific life event.

It analyzes **energetic tendencies** — favorable / unfavorable windows, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Useful for:

- Reading the energy around a specific date or month — e.g. a known event like the Meta 5/20 layoff
- Adding a second lens to long-horizon planning — fundraising windows, launch timing, key hires — *alongside* (never instead of) the actual analysis you'd normally do

---

## Why this skill exists

LLMs **cannot reliably compute Bazi pillars**. The math is unforgiving:

- Solar-term boundaries (立春, 惊蛰...) shift the month at precise minutes, not on the 1st
- 子时 day-rollover is ambiguous (晚子时 vs 早子时)
- 60-cycle day-pillar arithmetic needs accurate Julian Day calculation
- True solar time correction matters

This skill solves it by delegating **all** arithmetic to [`lunar_python`](https://pypi.org/project/lunar-python/) (a validated port of `6tail/lunar`), and using the LLM only for interpretation.

---

## 📦 Install

```bash
pip install lunar_python
```

1. Download `bazi-reader.skill` from this folder.
2. Drop it into `~/.claude/skills/` (or `.claude/skills/` for per-project).
3. Restart Claude Code (or reload skills).

---

## When it triggers

- *"Bazi"* / *"八字"* / *"four pillars"* / *"日主"*
- *"[my/their] Chinese birth chart"*
- *"流月"* / *"monthly forecast"* (Chinese style)
- Any ask for an **energy reading** when birth datetime is provided

---

## Design principles

| | |
| :--- | :--- |
| **1. Deterministic calc, LLM interp** | Never let the LLM compute pillars. |
| **2. Playful, not fatalistic** | Energy tendencies, not predictions. |
| **3. No harmful predictions** | No layoffs, illness, death, relationship endings. |
| **4. Modern voice** | Sharp friend with Bazi knowledge, not mystical sage. |
| **5. Short by default** | 400–600 words. Expand only when asked. |
