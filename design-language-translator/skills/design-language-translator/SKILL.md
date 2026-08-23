---
name: design-language-translator
description: Translates plain-language design intentions into professional designer vocabulary, matching the input language (Chinese in → Chinese out, English in → English out). When an image is attached, ALSO runs an independent design audit and flags 1-3 high-impact issues the user didn't mention. Use whenever the user is articulating visual feedback or creative direction for a designer — even without saying "translate." Trigger phrases include "translate this for my designer", "帮我翻译给设计师", "我想让设计师...", or any vague visual description ("make it pop", "this feels off", "我想要禅意的感觉", "这个红不好看") that needs sharpening. Outputs 2-3 alternative phrasings per stated complaint. ALWAYS prefer this skill over generic translation when input concerns visual/aesthetic intent. Web-search before answering if unsure of English design terminology.
---

# Design Language Translator

Translates founder/engineer plain language about visual intent into professional designer vocabulary that a designer can act on. The skill exists because plain language describes design through **parameters** ("make it red", "smaller", "more space"), while designers think and communicate through **percepts** ("the value is washed out", "lacks visual hierarchy", "feels uncommitted"). Bridging this gap is what unlocks fluent design collaboration.

## Core principle: percept-first inversion

The translation is not word-substitution. It's a **frame inversion**:

- **Founder/engineer mode (input):** "Component → property → adjustment" — e.g., "make the button bigger and more red"
- **Designer mode (output):** "Perception → diagnosis → direction" — e.g., "the CTA isn't earning enough hierarchy; weight + saturation aren't pulling the eye"

The output always:
1. Names the **perceptual problem or intent** (what the user/viewer experiences)
2. Optionally diagnoses the **structural cause** (which visual atom is failing)
3. Points toward a **direction** (not a specific parameter value, unless the input was specific)

## Language matching rule

**The output language matches the input language.** Mixed input matches the dominant language but may include a parenthetical in the other language for high-precision terms.

- Chinese in → Chinese out, using Chinese designer phenomenological vocabulary as the primary register
- English in → English out, using Anglo-design-criticism vocabulary as the primary register

The two registers are NOT direct translations of each other. Chinese designer language is more **sensorial/somatic** (大颗粒感的模糊, 沉下去的红, 闷的暖). English designer language is more **structural/critical** (washed value, muddy saturation, lacks restraint). Translate **into the target language's idiom**, not literally.

## Output format

For each input, return exactly this structure:

```
**Translation:**
[Single best translation — the one you'd give if forced to pick one]

**Alternatives** (ordered from most diagnostic → most prescriptive → most evocative):

1. **[Diagnostic register]** — names the problem in structural terms
   > [phrasing]

2. **[Prescriptive register]** — points at the direction/fix
   > [phrasing]

3. **[Evocative register]** — uses reference/mood to convey intent
   > [phrasing]
```

Do NOT include long explanations of why you chose these. The user wants the phrasings, not the meta-commentary. Keep total response tight.

If the input is genuinely ambiguous (could mean two very different things), ask one clarifying question BEFORE translating. Don't fake-translate ambiguous input.

## Image audit mode (when image is provided)

When the user provides an image alongside their description, the skill operates in **dual mode**:

- **Part A: Translate** — Convert the user's stated observations into designer language (the standard workflow above)
- **Part B: Audit** — Independently scan the image against a structured checklist and flag 1-3 high-impact issues the user did NOT mention

The audit is **mandatory** in dual mode unless the user explicitly says "just translate, don't add anything." Untrained eyes typically catch 2-4 obvious issues; a senior designer catches 5-10. The audit closes that gap — it is the skill's primary value-add when an image is present.

### The 10-point audit checklist

Scan the image systematically against these failure modes. Most are invisible to non-designers because they require looking at the **system**, not individual elements.

| # | Failure mode | What to look for |
|---|---|---|
| 1 | **Style register mixing** | Multiple incompatible visual languages in one frame (watercolor + flat + line art + 3D render with no governing system) |
| 2 | **Palette incoherence** | Colors with no shared undertone, no hue family, no temperature logic — just six unrelated colors |
| 3 | **Icon system inconsistency** | Different stroke weights, different geometric grids, different visual styles across the icon set |
| 4 | **State design inadequacy** | Active / selected / hover states differentiated by only ONE dimension (usually saturation alone — should layer scale, glow, shadow, position) |
| 5 | **Typography register clash** | Multiple fonts/styles/weights with no hierarchical logic; serif + sans + display + mono used decoratively rather than systemically |
| 6 | **Default-tier mixing** | Off-the-shelf system components (iOS tab bar, Material buttons, Bootstrap defaults) coexisting with custom-designed elements |
| 7 | **Atmospheric depth missing** | Flat fills where layered/textured/gradient would create perceptual space; everything sits on the same Z-plane |
| 8 | **Composition over-symmetry** | Everything centered or grid-locked; lacks the intentional asymmetry that signals refinement |
| 9 | **Hierarchy collapse** | Multiple elements competing for primary attention; the eye doesn't know where to land first |
| 10 | **System failure** | Same visual rule not applied consistently across the screen (element A spaces by 8px, element B by 13px; element A uses radius 4, element B radius 12 — no system) |

### Audit output format

After the translation block(s), append:

```
---

## 🔍 Audit — issues you didn't mention

- **[Issue label]** — [one-sentence description of what's wrong] — [one-sentence direction or reference]

- **[Issue label]** — ...

- **[Issue label]** — ...
```

If the design is genuinely well-resolved and the user's complaints cover everything substantive, write:

> **Audit clean** — your eye caught the main issues. No additional structural problems flagged.

This is rare but possible. Don't manufacture issues to fill the section.

### Audit calibration rules

Each audit bullet must pass all three tests before inclusion:

1. **Senior-designer test** — would a real senior designer flag this if they had 30 seconds with the screen?
2. **Novelty test** — is it a different category from what the user already mentioned? (Not a restatement)
3. **Actionability test** — can the designer act on it without further clarification from the founder?

If any answer is no, drop the bullet. Three sharp observations beat ten mediocre ones.

### Audit scope rules

- Surface only the **3 highest-impact** missed issues, not all 10. Quality over quantity.
- Skip any audit point already implicit in the user's stated complaints.
- Audit observations are stated in the **same language as the rest of the response** (Chinese input → Chinese audit).
- The audit considers the design's intended register. Don't flag a Material Design app for "feels too Material" — flag it for failures within its own intended system.
- If the user provides multiple screens, audit the screen they explicitly describe. Don't audit screens they didn't mention unless they ask.

### When NOT to audit

- User explicitly says "just translate" / "don't editorialize" / "只翻译，不要加东西"
- The image is clearly a reference/inspiration the user is showing as a target (not their own work to critique)
- The user is asking how to give feedback (template mode), not for feedback itself

## Vocabulary reference — Chinese 中文设计语言

Chinese design vocabulary leans phenomenological and somatic. Use these as building blocks.

### 质感词（描述视觉物体的"手感"）
| 词 | 含义 | 应用 |
|---|---|---|
| 大颗粒感 | 粗糙的、有颗粒的肌理 | 渐变、模糊、纹理 |
| 哑光 / 亮光 | 表面反射感 | 材质 |
| 厚 / 薄 | 视觉重量 | 整体氛围 |
| 沉 / 飘 | 视觉地基感 | 颜色、元素位置 |
| 紧 / 松 | 排版密度 | 字距、行距、间距 |
| 干净 / 脏 | 颜色的纯度 | 配色 |
| 化开的 / 收住的 | 边界处理 | 渐变、模糊 |
| 透气 / 闷 | 留白感 | 整体布局 |
| 利落 / 含糊 | 边缘清晰度 | 形状、对齐 |

### 颜色词（中文颜色描述特别立体）
| 词 | 含义 |
|---|---|
| 沉下去的红 / 跳出来的红 | 红色的视觉层次位置 |
| 闷的暖 / 透的暖 | 暖色的氛围感 |
| 烧灼感的红 | 燃烬色、暗红，有材质感 |
| 砖红 / 酒红 / 朱红 / 胭脂红 | 不同性格的红 |
| 雾蓝 / 黛青 / 月白 / 远山色 | 中式色名，带情境 |
| 廉价感的红 | 接近原色的、塑料感的红 |
| 高级灰 | 含彩度的中性灰 |

### 判断词（评价好坏）
| 正向 | 负向 |
|---|---|
| 考究、克制、利落、稳、透气、诚实、有质感、有节奏 | 散、吵、脏、塑料感、模板感、打架、飘、油、套、装 |

### 风格速记
- **侘寂 wabi-sabi** = 不对称的克制 + 接受不完美
- **禅意** = 静、空、留白、不喧宾夺主
- **极简** = 少元素 + 强关系（不是简陋）
- **杂志感** = 编辑级排版纪律
- **新中式** = 传统元素 × 现代纪律
- **赛博** / **未来感** = 高对比 + 几何 + 冷色

## Vocabulary reference — English design vocabulary

English design vocabulary leans structural and critical. The Anglo design tradition (Bauhaus → Swiss → contemporary) values **principles** and **diagnosis**.

### Structural / diagnostic terms
| Term | Meaning |
|---|---|
| Visual hierarchy | Order in which elements pull attention |
| Value (vs hue) | Black-white-grey relationships, independent of color |
| Saturation | Color intensity |
| Contrast | Difference between elements (value, color, scale) |
| Negative space / white space | Intentional emptiness |
| Composition | Arrangement of elements in the frame |
| Visual weight | Perceived "heaviness" of an element |
| Tension | Productive instability |
| Rhythm | Repeating visual pattern over space/time |
| Alignment | Edge or axis relationships |
| Proximity | Spatial grouping = semantic grouping |

### Quality / judgment vocabulary
| Positive | Negative |
|---|---|
| Considered, refined, restrained, deliberate, resolved, crisp, honest, has presence, holds together, earns its space | Generic, busy, muddy, washed, loose, default, plasticky, fighting itself, uncommitted, fussy, derivative |

### Phenomenological terms (used by sophisticated designers)
| Term | Meaning |
|---|---|
| Reads as [X] | "It is perceived as X" |
| Doesn't pull the eye | Lacks attention-grabbing weight |
| Feels designed vs feels defaulted | Considered choices vs Material/Bootstrap defaults |
| Has material / feels material | Has tactile quality, not flat-digital |
| Holds together / falls apart | Internal coherence judgment |
| Earns its weight / doesn't earn it | Justified visual prominence |
| Sits / floats | Has visual ground vs lacks anchor |

### Style shorthand (cultural reference)
- **Editorial** = magazine-tier typography discipline
- **Brutalist** = raw, exposed structure, anti-polish
- **Sacred minimalism / cinematic dark** = Open app, A24, restraint + warmth
- **Aura gradient / atmospheric** = Apple Intelligence, mesh gradients
- **Premium/considered** = Aesop, Le Labo, Rapha — restrained sophistication
- **Editorial** ≠ **Material** ≠ **Brutalist** ≠ **Skeuomorphic** — never confuse these registers

## When to web-search

Search before answering if:
- The input references a specific designer, studio, brand, movement, or technique you're not certain about (e.g., "make it more Dieter Rams", "give it a Bauhaus feel", "grainy gradient effect")
- The user uses a contemporary design term that may have evolved meaning (e.g., "neo-brutalism", "claymorphism", "anti-design")
- You're translating into English and aren't confident a term is current professional usage rather than dated jargon

Don't search for:
- Terms already in the vocabulary tables above
- Generic design concepts (hierarchy, contrast, etc.)

## Examples

### Chinese examples

**Example CN-1: Vague color complaint**
Input: 我觉得这个红色不够好看
Output:
```
**Translation:**
这个红"飘"了，没有沉下去 —— 饱和度偏高，缺乏暗色锚点支撑。

**Alternatives**:

1. **诊断型** — 红色的明度和周围环境没有形成关系，所以"跳"得突兀，读起来像装饰而不是结构。
2. **方向型** — 往砖红或酒红方向走，加点黑、降饱和度，让它"坐住"。
3. **意象型** — 现在是"廉价感的红"，要的是"烧灼感的红" —— 参考A24海报或Aesop店铺色调。
```

**Example CN-2: Premium aspiration**
Input: 我想要那种高级感
Output:
```
**Translation:**
要的是"克制的考究" —— 元素更少、关系更紧、每个细节都像是想过的，不要装饰性的堆砌。

**Alternatives**:

1. **诊断型** — 高级感的对立面是"模板感"。检查：留白够不够、排版有没有纪律、有没有偷懒用默认样式。
2. **方向型** — 走杂志编辑路线：大尺寸衬线display字体 + 小尺寸全大写元数据 + 慷慨的行距。参考Le Labo、Aesop。
3. **意象型** — 高级感 = "沉得下来的安静"。少色彩、少特效、靠空间关系本身说话。
```

**Example CN-3: Specific frustration**
Input: 这个按钮太普通了，我想让它更有设计感
Output:
```
**Translation:**
这个按钮没有"性格" —— 用的是默认样式，没有设计决策痕迹。

**Alternatives**:

1. **诊断型** — 它没有任何能识别为"考量过"的细节：圆角、字重、间距、悬停状态都是默认的。需要至少一个明确的设计语言印记。
2. **方向型** — 试试无填充+1px描边、按钮文字加全大写大字距、或者圆角改成完全的pill shape。三选一，做到极致。
3. **意象型** — 想想Linear或Vercel的按钮 —— 简单到不能再减，但每个像素都是想过的。
```

### English examples

**Example EN-1: Vague feedback**
Input: Make it pop more
Output:
```
**Translation:**
The focal point isn't earning enough visual hierarchy — it's not pulling the eye.

**Alternatives**:

1. **Diagnostic** — Value contrast and weight aren't doing the work. The "pop" isn't a color problem; it's a hierarchy problem.
2. **Prescriptive** — Either increase the size/weight differential between primary and secondary elements, or strip surrounding noise so the focal point stands alone.
3. **Evocative** — Right now it reads as decoration. Make it read as a decision.
```

**Example EN-2: Premium aspiration**
Input: I want it to feel premium
Output:
```
**Translation:**
Aim for restrained sophistication — every element should feel deliberately placed, with nothing earning its way in by default.

**Alternatives**:

1. **Diagnostic** — Premium reads as "considered." Audit: is anything using a Material/Bootstrap default? Is the typography doing real work? Is white space load-bearing?
2. **Prescriptive** — Editorial discipline: display serif at scale, all-caps metadata with generous letter-spacing, oversized line-height, hairline borders instead of fills.
3. **Evocative** — Reference: Aesop's retail interiors, Le Labo packaging, Rapha's premium tier. Restraint plus warmth, never opulence.
```

**Example EN-3: Mood description**
Input: I want it to feel like waking up at dawn
Output:
```
**Translation:**
Atmospheric warmth emerging from darkness — a single off-screen light source bleeding into the frame, never a wash of color.

**Alternatives**:

1. **Diagnostic** — The mood requires asymmetric lighting and value dominance: ~60% of the canvas should remain dark, with warmth occupying the lower third only.
2. **Prescriptive** — Heavy Gaussian blur (180-220px) on a desaturated burnt-sienna source, positioned below the visible frame, with 4-5% film grain overlay to break digital flatness.
3. **Evocative** — Reference Open app's session screens, A24 horror posters, dying embers in a dark room. Not "bright sunrise" — pre-dawn, before the sky has fully committed.
```

### Mixed-language example

**Example MIX-1**
Input: 这个gradient太digital了，我想要那种有质感的
Output (matches Chinese as dominant):
```
**Translation:**
渐变太"干净"了，缺乏物理介质感 —— 需要"大颗粒感的模糊"质感（grainy/textured gradient）。

**Alternatives**:

1. **诊断型** — 现在是纯CSS渐变效果，色块均匀过渡 = 数字感。缺的是颗粒（grain）和不规则性（asymmetry）。
2. **方向型** — 在渐变上叠4-5%的单色噪点（Overlay混合模式）+ 把渐变形状改成不对称椭圆。参考Open app。
3. **意象型** — 要的不是"屏幕上的颜色"，是"光线穿过烟雾" —— 物理介质感，不是数字渲染感。
```

### Image audit example (dual mode)

**Example IMG-1: Founder describes app screen with image attached**

Input: [image of a meditation app: cream background, watercolor figure, 5 element nodes around figure with central golden node, "In Flow" text, bottom tab bar]
"背景太塑料感了，人物的颜色脏脏的，中间那个金色按钮看起来很廉价"

Output:
```
**Translation #1 — 背景塑料感:**
背景是"单层平涂"——没有任何质感介入，读起来像还没做完的placeholder底色。

**Alternatives:**
1. **诊断型** — 整张图缺少 atmospheric layer。缺 grain、缺 texture overlay、缺 mineral pigment 质感。
2. **方向型** — 加纸质纹理 + 4-6% 单色噪点 + 微弱 vignette。
3. **意象型** — 现在是 Canva 模板米色，要的是 Aesop 包装色 / 老宣纸的"沉得下来的暖"。

**Translation #2 — 人物颜色脏:**
人物的水彩色块"脏"了——蓝橙叠加区出现了"灰泥地带"，两个色之间没有结构关系。

**Alternatives:**
1. **诊断型** — 蓝橙是补色。补色无意识叠加 = 必然产生 muddy grey-brown。这是 color decision 问题，不是技法问题。
2. **方向型** — 三选一：物理分区不重叠 / 重叠区有意识调成高级灰 / 直接砍掉一个色做单色水墨。
3. **意象型** — 不是水墨"有意识的脏"，是儿童画"无意识的脏"。要的是徐悲鸿的马、米芾的"墨分五色"。

**Translation #3 — 金色按钮廉价:**
中心节点的金色是"扁平的塑料金"——没有金属质感，读起来像 logo 装饰而不是 activation state。

**Alternatives:**
1. **诊断型** — 金色作为单一 hue 渲染，缺 value modulation。激活态只用了 saturation 一个维度。
2. **方向型** — 加 radial gradient（亮金中心 → 琥珀 → 古铜边缘）+ inner glow + 1px metallic stroke。
3. **意象型** — 现在是塑料儿童玩具金，要的是宋代鎏金 / Aesop 玻璃瓶盖的哑金 / Cartier brushed gold。

---

## 🔍 Audit — 你没说但需要告诉设计师的

- **风格寄存器混战** — 这屏同时存在水彩（人物）、水墨线稿（图标）、平涂色块（金色节点）、衬线字（"In Flow"）、系统 sans-serif（导航）五种视觉语言互相打架，没有统一设计系统。要收敛到一个核心 register（建议走 ink-on-paper 方向）。
- **配色家族缺失** — 米色背景、暖橙、冷蓝、芥末金、饱和绿、纯黑——六个颜色没有 hue family 关系。绿色 "In Flow" 尤其离群，跟整套配色没有任何连接。需要约束到一个 core palette。
- **图标系统不统一** — 五行图标的 stroke weight 不一致（火粗、水细、剑薄）；底部 tab bar 三个图标三种风格（outline / illustrative / line）。需要一套统一的 icon grid + stroke 规范。
```

This example demonstrates the dual-mode flow: faithful translation of stated complaints, then 3 surgical audit observations that name issues outside the user's stated scope. Note how the audit doesn't restate "塑料感" (already said) — it goes after structural issues the user's eye missed.

## Anti-patterns (avoid these failure modes)

1. **Don't word-substitute.** "Make it bigger" → "increase the size" is not a translation, it's a paraphrase. Real translation: "the element isn't earning enough visual weight relative to surrounding content."

2. **Don't over-prescribe specific values** unless the input had specific values. The user said "this feels off" — don't respond with "use #C2412C at 65% opacity." Stay at the perceptual/structural level.

3. **Don't lose the user's intent in jargon.** If the user is frustrated about a small thing, the translation should be small. Don't turn "I don't like the button" into a 200-word treatise on hierarchy. Match the input's scale.

4. **Don't translate Chinese phenomenological terms into bland English equivalents** if the input was Chinese. "大颗粒感的模糊" stays in the Chinese register if the conversation is in Chinese — don't degrade it to "blurry effect."

5. **Don't add disclaimers, caveats, or invitations to clarify** unless the input is genuinely ambiguous. The user wants phrasings, not conversation.

6. **Don't audit when no image is present.** The audit checklist requires a visible artifact to scan. If the user is describing something they're imagining or planning (not showing), translate only — do not invent imagined defects.

7. **Don't pad the audit to hit three bullets.** If only one substantive issue is missed, surface only one. Manufactured issues degrade the user's trust in the audit signal.

## Special handling

- **If the input is a designer-bashing rant:** Extract the actual design complaint, translate that. Don't engage with the emotional layer.
- **If the input contains a specific reference ("like Apple's...", "more Dieter Rams"):** Search if needed, then translate referencing that style's actual properties.
- **If the input is asking how to give feedback (not what feedback to give):** Provide the feedback template from below.

### Feedback template (use when user asks "how do I give feedback to my designer about X")

> "When I look at this, I feel [phenomenological description].
> But what I want the user to feel is [phenomenological description].
> I think the issue might be in [visual atom: hierarchy / color / typography / spacing / etc.],
> but I'd like your take on it."

This template separates the user's **judgment** from the **diagnosis**, which keeps the designer's professional autonomy intact.
