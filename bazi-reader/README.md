# bazi-reader

A Claude Code skill that generates a personalized, playful Bazi (八字 / Chinese Four Pillars) reading from a birth datetime, including how the current monthly pillar (流月) interacts with the personal chart.

## What it does

Given a birth year / month / day / hour, the skill returns:

- **Your chart** — the four pillars + day master
- **You × the current month (流月)** — how this month's pillar interacts with your chart, via Ten God relationships and any branch 冲 / 合
- **Today's energy** — the day pillar of the date being analyzed
- **Working with this week** — concrete do / don't items, framed as energy guidance, never specific predictions

Optional: a `--analyze-date` flag lets you point the reading at a specific date (e.g. `2026-05-20`) instead of today.

## What it is not

**Not a prediction tool.** It does not forecast layoffs, illness, financial outcomes, or any specific life event. It analyzes energetic tendencies — favorable / unfavorable windows, themes to lean into, friction to expect.

Treat the output as a **reference**, not a verdict. Useful for:

- Reading the energy around a specific date or month (e.g. a known event like the Meta 5/20 layoff)
- Adding a second lens to long-horizon planning — fundraising windows, product launch timing, key hires — alongside (never instead of) your actual analysis

## Why this skill exists

LLMs cannot reliably compute Bazi pillars. Solar-term boundaries (立春, 惊蛰...) shift the month at precise minutes, the 子时 day-rollover convention is ambiguous, and the 60-cycle day-pillar arithmetic needs accurate Julian Day calculation.

This skill solves it by delegating **all** arithmetic to `lunar_python` (a validated port of `6tail/lunar`), and using the LLM only for interpretation.

## Install

1. Download `bazi-reader.skill` from this folder.
2. Drop it into `~/.claude/skills/` or your project's `.claude/skills/`.
3. Install the calculation dependency:
   ```bash
   pip install lunar_python
   ```
4. Restart Claude Code (or reload skills).

## Triggers

- "Bazi" / "八字" / "four pillars" / "日主"
- "[my/their] Chinese birth chart"
- "流月" / "monthly forecast" (Chinese style)
- Any ask for an "energy reading" when birth datetime is provided

## Design principles

1. **Deterministic calculation, LLM interpretation.** Never let the LLM compute pillars.
2. **Playful, not fatalistic.** Energy tendencies, not predictions.
3. **No harmful predictions.** No layoffs, illness, death, relationship endings.
4. **Modern voice.** Sharp friend with Bazi knowledge, not mystical sage.
5. **Short by default.** 400–600 words. Expand only when asked.
