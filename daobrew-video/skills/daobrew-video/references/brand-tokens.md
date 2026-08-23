# DaoBrew brand tokens

Full catalog of colors, type, and spacing used across DaoBrew video work. `SKILL.md` links here for reference; consult when authoring new elements that need to feel on-brand.

## Colors

| Token                | Value                       | Use                                                                       |
|----------------------|-----------------------------|---------------------------------------------------------------------------|
| `brand-amber`        | `#ECA94C`                   | Primary accent. Outro `#oc-l2`, `#oc-wm`, amber `.dot.amber` chips.       |
| `brand-amber-glow`   | `rgba(236,169,76,0.45)`     | Amber glows / drop shadows around accent elements.                        |
| `brand-amber-dim`    | `rgba(236,169,76,0.85)`     | The `DAOBREW` wordmark.                                                   |
| `headline-ivory`     | `#F3EEE8`                   | Outro `#oc-l1`.                                                           |
| `body-cream`         | `#F4ECE2`                   | PiP `.pip-cap` label text.                                                |
| `bubble-dark`        | `rgba(9,6,4,0.88)`          | `.cap-inner` caption bubble.                                              |
| `outro-haze`         | `rgba(48,26,8,0.55)`        | Outro radial vignette center.                                             |
| `outro-edge`         | `rgba(0,0,0,0.98)`          | Outro radial vignette outer.                                              |
| `green-dot`          | `#7CF2A0`                   | PiP `.pip-cap .dot` (default, non-amber).                                 |

## Typography

- **Latin and brand font:** Plus Jakarta Sans ExtraBold (weight 800). Ship the woff2 from `assets/fonts/`.
- **Simplified Chinese caption font:** Hiragino Sans GB at a visually matched weight on Neo's Mac. For portable/non-Mac renders, bundle an approved CJK face and declare it explicitly. Never depend on an unnamed generic fallback.
- Letter-spacing: **tight** (`-0.01em` to `-0.02em`) for headlines and captions; **wide** (`0.42em`) for the `DAOBREW` wordmark.

### Sizes (rendered at 1920×1080)

| Element                | Font size | Weight | Notes                                       |
|------------------------|-----------|--------|---------------------------------------------|
| English caption (`.cap-single`) | 44px | 800 | Dark bubble bottom-center.                  |
| Bilingual Chinese (`.cap-zh`) | 44px | 600 | Primary line in Hiragino Sans GB.           |
| Bilingual English (`.cap-en`) | 32px | 800 | Secondary line in Plus Jakarta Sans.        |
| Outro `#oc-l1`         | 56px      | 800    | Ivory.                                      |
| Outro `#oc-l2`         | 70px      | 800    | Amber, with amber glow.                     |
| Outro `#oc-wm`         | 23px      | 800    | Wide letter-spacing `0.42em`.               |
| PiP `.pip-cap`         | 19px      | 800    | Lower-third on overlay.                     |

## Spacing / layout

- Composition default: **1920×1080 landscape, 30fps**.
- Outro icon: `196×196`, border-radius `44px`, with amber glow shadow.
- Captions sit `78px` above bottom edge, `max-width: 1200px`, centered.
- PiP panel margin from corner: `46px`.
- PiP overlay semi-transparency: `opacity: 0.86` on `.pip-media`.
- PiP halo: `inset: -22px`, `backdrop-filter: blur(7px)`, radial mask fade.

## Outro timing (relative to composition END)

| Tween                            | Offset from END | Duration | Ease              |
|----------------------------------|-----------------|----------|-------------------|
| `#footage` fade-out              | END − 4.7       | 0.9s     | `power2.in`       |
| `#outro` fade-in                 | END − 4.4       | 0.7s     | `power2.out`      |
| `#oc-icon` reveal                | END − 4.0       | 0.8s     | `back.out(1.5)`   |
| `#oc-l1` slide-up                | END − 3.5       | 0.5s     | `power3.out`      |
| `#oc-l2` slide-up + scale-up     | END − 3.2       | 0.6s     | `back.out(1.3)`   |
| `#oc-wm` fade-in                 | END − 2.6       | 0.5s     | `power2.out`      |

Total tail: ~4.7s. Plan composition `data-duration` to include this.

## PiP entrance/exit timing

| Phase    | From                              | To                                  | Duration | Ease              |
|----------|-----------------------------------|-------------------------------------|----------|-------------------|
| Entrance | `opacity: 0, scale: 0.96, y: -6`  | `opacity: 1, scale: 1, y: 0`        | 0.7s     | `power2.out`      |
| Exit     | (current)                         | `opacity: 0, scale: 0.99`           | 0.5s     | `power2.inOut`    |

Place entrance at `inAt`, exit at `outAt`. Pick `outAt` to leave ~0.5s of breathing room before the next overlay enters in the same corner.

## Caption entrance/exit timing

| Phase    | From                  | To                       | Duration | Ease           |
|----------|-----------------------|--------------------------|----------|----------------|
| Entrance | `opacity: 0, y: 26`   | `opacity: 1, y: 0`       | 0.3s     | `power3.out`   |
| Exit     | (current)             | `opacity: 0, y: -14`     | 0.22s    | `power2.in`    |

Exit timestamp: `Math.max(c.s + 0.25, c.e - 0.22)` — guarantees minimum on-screen time even for very short captions.
