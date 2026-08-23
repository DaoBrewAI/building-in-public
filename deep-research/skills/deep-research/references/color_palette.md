# Trust Gate Color Palette (Accessibility-Safe)

> **This palette avoids green for accessibility (colorblind users). PASS=blue, NEVER green.**
> Adapt this to your accessibility needs. The key principle: use distinct hues that are
> distinguishable under common color vision deficiencies.

## Tag → Color → Hex

| Tag | Semantic | RGB | Hex | Use cases |
|---|---|---|---|---|
| `[VERIFIED]` | PASS | (0.0, 0.4, 0.8) | `#0066cc` | finding verified against current source |
| `[LANDED]` | PASS (diff) | (0.0, 0.4, 0.8) | `#0066cc` | diff/PR status is merged/closed |
| `[STALE]` | PARTIAL | (0.85, 0.65, 0.0) | `#d9a600` | content drifted but symbol present; OR diff not merged when needs_diff_landed=true |
| `[DRAFT]` | PARTIAL (diff) | (0.85, 0.65, 0.0) | `#d9a600` | diff/PR status is draft or pending review |
| `[UNVERIFIED]` | FAIL | (0.85, 0.4, 0.0) | `#d96600` | could not verify (no evidence, or no match) |
| `[HALLUCINATED]` | FAIL+critical | (0.85, 0.0, 0.0) | `#d90000` | file/diff does not exist |
| `[ABANDONED]` | gray (diff) | (0.55, 0.55, 0.55) | `#8c8c8c` + strikethrough | diff/PR status is abandoned/closed without merge |
| `[UNKNOWN_STATUS]` | gray (diff) | (0.55, 0.55, 0.55) | `#8c8c8c` | diff/PR API unavailable |

## Accessibility Guidelines

- Avoid `green` (#00ff00, #008000, etc.) for PASS status -- many colorblind users cannot distinguish green from red/brown.
- Use `blue` (#0066cc) for PASS -- universally visible across color vision deficiencies.
- Reserve `red` only for critical failures (e.g., `[HALLUCINATED]`).
- Use `orange` for non-critical failures.

## Banner color rules

- `Trust Gate: PASS` → blue text + bold
- `Trust Gate: SOFT BLOCK` → yellow text + bold
- `Trust Gate: HARD BLOCK` → orange text + bold
- `Trust Gate: BYPASSED` → orange text + bold (force-deliver banner)

## Inline span template

```html
<span style="color: #0066cc; font-weight: bold;">[VERIFIED]</span>
```

## Validation regex (optional)

Auto-fail any rendered output matching green if accessibility is enforced:
```
green|#00[8a-f][0-9a-f]00|#0f0|#00ff00|color:\s*green
```
