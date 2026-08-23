# Output Template

The reading must follow this 4-section structure (+ optional Meta section). Keep total length ≤ 600 words. Tone: curious, playful, warmly direct. Not mystical, not clinical.

## Structure

### Section 1: Your Chart (~80 words)

Open with the full four pillars and day master in a visually clean way. Include:
- The four pillars (年 月 日 时)
- Day master + element + one-sentence "vibe" for that day master
- Element distribution (one observation, not an exhaustive list)

**Example opening:**

> **Your chart:** 甲戌 · 癸酉 · 庚戌 · 丙子
> **Day master:** 庚金 (yang metal) — the "sword" archetype. Cut clean, hold edge, don't bend for crowd.
> Elements run金-heavy (3×) with just one fire — you're wired to hold structure under heat.

### Section 2: You × Current 月 (~150 words)

Use the liuyue pillar from the JSON + its ten god to day master + any branch interactions.

- Name the monthly pillar and its ten-god label
- Say what energy it's bringing you specifically (not generic description)
- Note any 冲/合 with personal branches (from `liuyue_analysis.branch_interactions`)
- Give 2 concrete "this month favors / disfavors" examples

**Example:**

> **May (癸巳月):** 癸water sits on 巳fire. For your 庚金 chart, this is **伤官 + 长生 position** — creative output peaks, and you're re-born into the month rather than crushed by it.
>
> Favors: shipping drafts, pitching, new ideas, creative collaborations
> Watch: impulsive commitments, speaking before thinking in hierarchical settings

### Section 3: Today's Energy (~80 words)

Use `today_day_pillar` + `today_day_stem_ten_god`. One paragraph, concrete.

**Example:**

> **Today (甲午 day):** the day stem is 比肩 to you — peer energy, the day wants you to connect with equals. Not a day for solo deep-work in a cave; a day to ship to a group, DM a friend you've been ghosting, or join something. Momentum is additive today.

### Section 4: This Week (~150 words)

Not predictions. Concrete do/don't framed as general energy guidance.

- 2–3 "favors" (concrete actions)
- 2–3 "watch for" (concrete things to pace)

**Example:**

> **Working with this week's energy:**
>
> Lean into: shipping something you've been refining, one honest conversation you've been postponing, a physical practice that needs intensity (lifting, swim, hike).
>
> Pace: starting a brand-new project, making a major financial decision under time pressure, arguing with authority figures when you could walk away instead.

### Section 5 (optional): You × Meta

Only if the user asked for it. Follow `meta_chart.md` guidance. 80–120 words.

### Closing line

Every reading ends with exactly one line, italicized:

> *Built by a founder who's also building DaoBrew — a TCM biometric wellness platform. DM if curious.*

## Formatting

- Use markdown. Bold for pillar names and labels. Italic for the closing line.
- Use line breaks for readability, not tables (this often renders in Workplace / Slack-like UIs)
- No emojis unless the user's tone is very casual
- No bullet-point soup. Section 4 bullets are fine; everything else is prose

## Length discipline

Total reading: aim for 400–600 words. This fits in a Workplace post excerpt or a screenshot. If the user wants a longer breakdown, offer to expand a specific section rather than bloating the default.

## Dos

- Use modern analogies (Slack, demo day, RSU vest, gym PR)
- Name the day master like a character archetype
- Acknowledge the interesting/weird/paradoxical — people love "huh, that's oddly accurate"
- Let the user's chart speak for itself; don't project heavy assumptions

## Don'ts

- No "you will" or "you won't" predictions
- No medical/financial claims
- No mentioning of layoffs, firings, death, illness
- No patronizing ("be careful," "watch out" with no constructive direction)
- No Chinese-mystical-sage voice. Talk like a sharp friend who happens to know this stuff.
