# Bazi Reader Skill

A Claude Skill that generates playful, personalized Bazi (八字 / Chinese Four Pillars) readings.

## Architecture

```
bazi-reader/
├── SKILL.md              # Main entry point, triggers + workflow
├── scripts/
│   └── compute_bazi.py   # Deterministic 4-pillar calculator (lunar_python)
├── references/
│   ├── ten_gods.md       # 十神 meanings (modern framings)
│   ├── liuyue_2026.md    # 2026 month-by-month energy framework
│   ├── meta_chart.md     # Optional Meta compatibility layer
│   └── output_template.md # Output structure + tone rules
└── README.md
```

## Why this architecture

**LLMs cannot reliably compute Bazi pillars** because of:
- Solar-term boundary slippage (立春, 惊蛰, etc. — the month changes at precise minutes, not the 1st of the Gregorian month)
- 子时 day-rollover convention (晚子时 vs 早子时 — whether 23:00–24:00 rolls to next day)
- 60-cycle day-pillar arithmetic that requires accurate Julian Day calculation
- True solar time correction

**This skill solves it** by delegating ALL arithmetic to `lunar_python` (a validated Python port of the well-regarded `6tail/lunar` library), and using the LLM only for interpretation.

## Installation

```bash
pip install lunar_python
```

## Usage

Drop the skill folder into your Claude Skills directory. The skill triggers on:
- "Bazi" / "八字" / "four pillars" / "日主"
- "[my/their] Chinese birth chart"
- "Chinese astrology reading"
- "流月" / "monthly forecast" (Chinese style)
- Any ask for an "energy reading" when birth datetime is provided

## Script usage (standalone)

```bash
python scripts/compute_bazi.py \
  --year 1994 --month 10 --day 5 \
  --hour 23 --minute 30 \
  --analyze-date 2026-05-20
```

Output: JSON with 4 pillars, Ten Gods, current Liuyue, and today's day pillar.

## Design principles

1. **Deterministic calculation, LLM interpretation.** Never let the LLM compute pillars.
2. **Playful, not fatalistic.** Energy tendencies, not predictions.
3. **No harmful predictions.** No layoffs, illness, death, relationship endings.
4. **Modern voice.** Sharp friend with Bazi knowledge, not mystical sage.
5. **Short by default.** 400–600 words. Expand only when asked.

## Extending

- Add more company charts to `meta_chart.md` for other workplace contexts
- Add references for other years (2027丁未, 2028戊申, etc.) — copy the structure of `liuyue_2026.md`
- For romantic compatibility ("我和对象合盘"), build a new reference with 夫妻宫 / 合盘 framework
- For health readings, explicitly avoid medical claims — frame as "energetic tendencies around energy/sleep/digestion themes"

## Credits

- `lunar_python` by 6tail — does all the heavy lifting
- 十神 interpretation framings adapted from classical 子平 framework, modernized
