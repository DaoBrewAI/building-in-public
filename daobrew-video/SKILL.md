---
name: daobrew-video
description: "Apply DaoBrew's video editing house style to HyperFrames compositions — captions sourced from the original script (not raw ASR), big readable semi-transparent overlays that show founders through, soft-blended PiP panels with subtle name labels, and the DaoBrew amber + Plus Jakarta Sans outro card on the tail. Use whenever building or editing any DaoBrew video (pitch, demo, marketing, social), authoring captions for a DaoBrew composition, placing asset overlays (sentinel, breath, mcp, b2b, etc.) over founder footage, or adding the DaoBrew ending frame. Always use the templates/ snippets verbatim instead of reinventing the styling. Do NOT use for non-DaoBrew video work — defer to /hyperframes house style instead."
---

# DaoBrew video house style

Brand/style layer for HyperFrames. The framework engine (data-attributes, timeline registration, etc.) is owned by `/hyperframes` — this skill adds the DaoBrew look on top.

## When this skill fires

DaoBrew video work in HyperFrames: pitches, product demos, marketing clips, social cuts. Whenever you're writing captions, placing asset overlays over founder footage, or wrapping a composition with the ending frame.

Defer to `/hyperframes` for framework rules. Defer to `daobrew-wellness` for biometric/wellness session features.

## Core principles (the user's commandments)

1. **Captions = script text.** ASR is for timing only. Where speech improvises away from the script, follow the script wording — it's the polished, deliberate text.
2. **Never trim, freeze, or staticize a source asset.** If a thing is animated on the source, it must be animated in the video. Each asset plays its full natural duration in motion.
3. **Never blur, crop, or modify the primary speaking footage.** It stays pristine. Founder video is sacred.
4. **Overlays must blend in.** Soft floating insets, gentle fades. Never the chunky stuck-on box look. No hard amber borders, no obvious frames.
5. **Always keep a subtle name label** on each overlay (lower-third gradient + a small brand-colored dot) so viewers know what the asset is.
6. **When multiple overlays play in the same window, spread them to different corners** (top-left + top-right). Don't stack them in the same corner.
7. **Bias toward big.** Readable beats restrained. Half-screen overlays are fine.
8. **When a big overlay covers a face, the panel video must be semi-transparent** (`opacity: 0.86` on `.pip-media`) so the founder shows through, plus a subtle backdrop-blur halo at the edge.
9. **Verify visually** with `npx hyperframes snapshot --at <times>` at every moment ≥1 overlay is active. Never trust assumption.
10. **Use J-cuts for short-form pacing when a solo/talking-head clip would drag.** For TikTok/Reels/viral shorts, especially office-style solo clips, consider starting the next clip's voice under the previous visual before cutting to the speaker. If the exact cut point is not specified, ask Neo whether a J-cut is needed and which frame/moment should reveal the new visual. Keep the visual cut aligned to the first useful expression, gesture, or action instead of showing several dead seconds of setup.
11. **Use L-cuts when a spoken setup should immediately reveal the imagined/action payoff.** An L-cut cuts the picture to the next clip while the outgoing clip's audio/caption continues over the new visual. In DaoBrew gym/pitch shorts, use this when Neo names the upcoming action or imagined scenario and the viewer should see it before the sentence fully ends. Keep the overlap short, usually under 1.5s, and align the visual cut to the strongest first frame of the payoff clip.
12. **End every DaoBrew video with the standard outro card** from `templates/outro-card.*`. Tagline is parameterized via HyperFrames composition variables.
13. **Never sacrifice source resolution for a master.** A master render may not downscale source footage, force 10-bit footage into an 8-bit master, or hide quality loss behind a platform export. Lower-resolution/platform exports are allowed only after a high-fidelity master exists.
14. **Analysis artifacts are never source pixels.** Extracted frames, screenshots, thumbnails, contact sheets, OCR crops, proxies, reveal frames, and OpenCV outputs are analysis-only. They may identify timecodes, layout, spacing, subject position, or visual differences, but they may never be placed into or encoded into a master or platform derivative. Render every final pixel from the original source media or another user-approved creative asset through a high-fidelity renderer such as ffmpeg/HyperFrames; never use OpenCV `mp4v` or analysis-frame intermediates in the final visual path.
15. **Every remaster session needs a source-vs-remake reveal.** Before marking a clip done, compare original source, old lossy render when available, and new remake with `ffprobe`, decode checks, still frames, and a color/detail sanity check. Fail the session if unintended downscale, crop, color wash, softness, or unsupported color metadata appears.
16. **Lock source orientation and aspect ratio.** Never convert landscape ↔ portrait, rotate, crop, or reframe into another aspect ratio without Neo's explicit approval for that deliverable. A Xiaohongshu or X/Twitter destination does not authorize an orientation change. Masters inherit the source orientation and aspect ratio; platform derivatives may resize only within that same orientation unless approved.
17. **Platform subtitle variants are separate deliverables.** Xiaohongshu gets bilingual Simplified Chinese + English captions; X/Twitter gets English-only captions, unless Neo explicitly says otherwise. Both variants share one script-derived timing map, use language-specific line breaks, and have distinct filenames. Never derive final wording from raw ASR.
18. **Hooks are source-media cold opens, not copywriting.** Before editing, scan the actual source video and propose strong visual/spoken excerpts with exact source in/out timecodes and a recommended choice. Do not begin editing until Neo selects a hook or explicitly delegates the choice. Build the cold open by moving or duplicating that excerpt on the timeline while decoding its final pixels directly from the original media. Analysis frames, screenshots, contact sheets, thumbnails, and proxies may be used only to choose timecodes; they must never appear in the rendered video.
19. **Caption typography must be designed, not left to accidental fallback.** Use an explicitly declared font for every rendered language, visually inspect bilingual hierarchy and wrapping, and fail QA on missing glyphs, tofu, accidental fallback, awkward wrapping, or oversized karaoke-style text.

## Keeping this skill current

When Neo states a new durable DaoBrew video rule that is missing here, update this `SKILL.md` and every directly affected template/reference in the same task, then report exactly what was added. Do not promote a one-off per-video creative choice into a global default unless Neo indicates it is durable.

## Brand tokens (quick reference)

- Amber accent: `#ECA94C` · Headline ivory: `#F3EEE8` · Cap-bubble dark: `rgba(9,6,4,0.88)`
- Latin and brand font: **Plus Jakarta Sans** weight 800 (ExtraBold). Ship the woff2 from `assets/fonts/`. For Simplified Chinese captions on Neo's Mac, explicitly use **Hiragino Sans GB** at a visually matched weight; for non-Mac or portable renders, bundle an approved CJK face and name it explicitly. Never rely on an unnamed generic fallback.
- Default composition: **1920×1080 landscape, 30fps** for new HyperFrames comps only. Existing footage masters inherit source resolution/color first; platform size is a derivative export decision, not the master format.

Full catalog: [references/brand-tokens.md](references/brand-tokens.md).

## Using the outro card (the lifted ending frame)

Always end a DaoBrew video with this. Steps:

1. Copy `assets/daobrew_icon.png` → project root.
2. Copy `assets/fonts/PlusJakartaSans-ExtraBold.woff2` → project's `fonts/` directory.
3. Read `templates/outro-card.variables.json` → merge its two entries into the root `<html data-composition-variables='[...]'>` array (create the attribute if not present).
4. Read `templates/outro-card.html` → append just before the closing `</div>` of the root composition.
5. Read `templates/outro-card.css` → merge into the composition's `<style>` block (dedup the `@font-face` if already declared elsewhere).
6. Read `templates/outro-card.gsap.js` → append into the composition's timeline `<script>`. Set the `END` constant at the top to the composition's final time literal (e.g. `const END = 60;` for a 60-second composition). The card occupies the final ~4.7 seconds.
7. Override the tagline at render time when a particular video wants different lines:
   ```
   npx hyperframes render --variables '{"outro_l1":"Your line","outro_l2":"Second line."}'
   ```
   The default values render the standard DaoBrew tagline: `Find the work-stress root cause.` / `One click. Brief your agent. Detonate.`

## Using the caption templates

For dark-bubble captions synced to a voiceover:

1. Read `templates/caption.css` → merge into `<style>`.
2. Add `<div id="cap-layer"></div>` inside the root composition div.
3. Author a `window.__CAPS` array — use `{ t, s, e }` for English-only captions and `{ zh, en, s, e }` for bilingual captions. Source all wording from the user's script and use `hyperframes transcribe` only to anchor times. Drop it in a `captions.data.js` file loaded before the main timeline script.
4. Read `templates/caption.gsap.js` → append into the timeline `<script>` (it consumes `window.__CAPS` and creates the visible caption elements).

## Using the PiP overlay templates

For asset overlays over founder footage:

1. Read `templates/pip-panel.css` → merge into `<style>`. This encodes the semi-transparent + backdrop-blur halo + lower-third label treatment.
2. For each overlay, add markup of the shape:
   ```html
   <div class="pip" id="pip-NAME">
     <div class="pip-blur"></div>
     <div class="pip-frame">
       <video id="m-NAME" class="clip pip-media"
              data-start="..." data-duration="..." data-track-index="N"
              src="..." muted playsinline></video>
       <div class="pip-cap"><span class="dot"></span>NAME</div>
     </div>
   </div>
   ```
3. Add per-id positioning rules (`#pip-NAME { top: 46px; right: 46px; transform-origin: 100% 0%; }`) and per-id media sizes (`#pip-NAME .pip-media { width: 920px; height: 720px; }`). Put each video on its own `data-track-index`.
4. Read `templates/pip-panel.gsap.js` → append into the timeline `<script>`. Fill the `PIPS` array with `{ sel, inAt, outAt }` entries per overlay.

## Verification checklist before render

- [ ] Snapshot at every moment where ≥1 overlay is active.
- [ ] Confirm overlay video plays in motion — compare two rendered frames ~1.5s apart, content must change (not frozen).
- [ ] Confirm no panel covers a face without semi-transparency (`opacity: 0.86`).
- [ ] Confirm caption text matches the script, not the ASR.
- [ ] Confirm the outro card fades in correctly at `END - 4.7` and the icon/lines/wordmark stagger as defined.
- [ ] Confirm every proposed hook identifies exact source in/out timecodes and was selected before editing began.
- [ ] Confirm the cold open is rendered directly from the original source-media excerpt at the selected timecodes.
- [ ] Confirm no analysis frame, screenshot, contact sheet, thumbnail, OCR crop, or proxy contributes final pixels.
- [ ] Confirm orientation and aspect ratio match the source unless Neo explicitly approved a change.
- [ ] Confirm Xiaohongshu is bilingual and X/Twitter is English-only, with distinct filenames and one timing map.
- [ ] Confirm Chinese glyphs use the declared CJK face with no missing glyphs, accidental fallback, or awkward bilingual wrapping.
