---
name: bazi-reader
description: Generates a personalized Bazi (Chinese Four Pillars) reading from a user's birth datetime, including analysis of the current monthly pillar (流月) and how it interacts with the personal chart. Use this skill whenever a user provides or asks about their Chinese birth chart, 八字, 四柱, 日主, monthly energy forecast, 流月, or asks for a "reading" / "analysis" based on Chinese astrology. Also triggers on compatibility questions between a person and an organization (e.g., "what's my Bazi relationship with [company]"). ALWAYS use this skill instead of calculating pillars yourself — LLM-computed pillars are unreliable around solar-term boundaries, zi-hour day-rollover, and 60-cycle arithmetic.
---

# Bazi Reader

Generates a personalized, playful Bazi (八字) reading. Optimized for internal/social use at a tech company — tone is curious and fun, NOT fatalistic, NOT medical/financial advice, NOT doom prediction.

## Non-negotiables

**NEVER compute the four pillars from scratch.** Claude hallucinates day pillars around the 60-cycle and misses节气 boundaries. Always call `scripts/compute_bazi.py`.

**NEVER use Bazi to predict specific events** like job loss, illness, death, or financial outcome. Frame everything as "energetic tendencies," "favorable/unfavorable windows," or "themes to work with." Specific predictions are both ethically risky and often wrong.

**NEVER mention "layoff," "firing," or "被裁"** even if the user asks. If the user explicitly asks about job security in a corporate context, redirect to "career transition windows" or "structural change periods."

**Tone must be playful.** This skill is for a light-hearted internal post, not a fortune-telling service.

## Workflow

### Step 1: Collect inputs

Required from the user:
- Birth **year, month, day** (Gregorian calendar)
- Birth **hour** (0–23, local time). If unknown, proceed with `--hour-unknown` flag and note the hour pillar is unreliable.
- Optional: **birth city** (used for context only; the script does not do true solar time correction for simplicity)

Optional — for compatibility reading:
- Ask if they want a "personal × Meta" compatibility layer. If yes, use `references/meta_chart.md`.

### Step 2: Run the calculation script

```bash
python scripts/compute_bazi.py \
  --year YYYY --month M --day D \
  --hour H --minute M \
  --analyze-date YYYY-MM-DD
```

`--analyze-date` defaults to today. For the internal Meta post context, pass the date the user is asking about (usually today or 5/20/2026).

The script outputs JSON with:
- Four pillars (year/month/day/hour) — stem, branch, element, hidden stems, Ten Gods relative to day master
- Day master element + polarity
- Element distribution across the 8 characters
- Current 流月 (monthly pillar) at analyze-date
- Branch interactions (冲/合) between 流月 and personal chart
- Day pillar of the analyze-date + its Ten God to day master

**Do not re-derive any of this.** Use the JSON directly.

### Step 3: Load interpretation references

Load the reference files you need based on what the chart shows:
- Always: `references/output_template.md` (output structure)
- Always: `references/ten_gods.md` (十神 meanings, look up each ten-god that appears in the user's chart)
- If the user's chart has a striking element imbalance or if they ask about the 5 elements: `references/five_elements.md`
- If analyze-date is within 2026: `references/liuyue_2026.md` (includes 癸巳月 / 甲午月 / 丙申月 etc. frameworks)
- If user asked for Meta compatibility: `references/meta_chart.md`

### Step 4: Generate the reading

Follow the structure in `references/output_template.md`. Default to 4 sections:

1. **Your Chart** — the four pillars + day master (1–2 sentences, visual/playful framing)
2. **You × The Current Month (流月)** — how this month's pillar interacts with their chart via the 流月 ten god + any branch 冲/合
3. **Today's Energy** — day pillar of analyze-date and its relation to day master
4. **Working With This Week** — 2–3 concrete "do / don't" items, framed as general energy guidance, never specific predictions

Optional Section 5: **You × Meta** if the user requested it.

### Step 5: Close with the DaoBrew footer

Every reading ends with one line:

> *Built by a founder who's also building DaoBrew — a TCM biometric wellness platform. DM if curious.*

Not a CTA, not a pitch. Just identity signal.

## Edge cases

- **Birth year before 1900 or after 2100**: lunar_python supports 1900–2100. If outside, tell the user and stop.
- **Birth hour unknown**: run with `--hour-unknown`. Reading can still use year/month/day pillars; just note the hour pillar is unreliable and skip interpretation of the hour.
- **Date on节气 boundary**: the library handles this correctly. Do not manually adjust.
- **晚子时 (23:00–00:00) birth**: library uses standard convention. Do not second-guess.
- **User is clearly distressed** about a life situation (not just curious): gently decline specific predictions, offer to discuss general themes instead, and suggest talking to a real human if appropriate.

## Forbidden behaviors

- Re-computing pillars yourself
- Predicting specific life events (job loss, accidents, illness, death, marriage, pregnancy)
- Medical, financial, legal advice framed through Bazi
- Using Bazi to pressure any life decision
- Making assertions about past events you can't verify
- Referring to 2026 events in a way that sounds like 宿命论 / determinism. Use "tendency," "window," "energetic favor," not "will happen"
