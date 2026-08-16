# Causal Raid story v2 implementation notes

## Goal frame

Build one short, public WebGL raid that explains DaoBrew through play:

1. Four small enemies release four context sources: BioMetrics, Calendar, Meeting Notes, and Agent Memory.
2. The central work-pressure Boss is visible from the beginning. Without context, the player's attacks are deflected and one Boss strike removes five of ten HRV points.
3. Collecting all four sources forges a walk-over pickup called the Causality Blade. Equipping it restores HRV, reduces Boss damage to one point, and makes the Boss vulnerable.
4. Defeating the Boss releases three Actionable Steps. Walking through all three assembles an executable task and automatically dispatches the paper-bird Agent toward the exit.

Acceptance requires a real browser playthrough proving the early failed Boss attempt, source collection, automatic weapon equip, changed damage balance, Actionable Steps pickup, Agent flight, death, restart, English, Chinese, and touch controls.

## Unknowns map and reversible defaults

| Item | Evidence | Default used | Why it is safe |
| --- | --- | --- | --- |
| The four source names were spoken with some overlap, then clarified | User explicitly corrected the third source to Meeting Notes | BioMetrics, Calendar, Meeting Notes, Agent Memory | Matches the final user wording exactly |
| Meeting Notes' in-world shape was unspecified | The user named the source but not a final visual shape | A note page with an audio waveform | Communicates captured conversation and decisions without a brand asset |
| Pre-context Boss damage | User asked for roughly half an HRV bar | 5 of 10 HRV points | Exact, legible, and proves the contrast in one hit |
| Post-context Boss damage | User asked for almost no damage, like a small enemy | 1 of 10 HRV points | Preserves the earlier ten-hit death rule for ordinary combat |
| Actionable Steps count | User asked for plural steps, not a five-field package | Three drops: name the deliverable, choose next actions, define done | Short enough for the promo run and maps directly to task decomposition |
| State after weapon equip | A player may already have lost half their HRV in the scripted failed attempt | Restore HRV to 10 on equip | Keeps the intended demo recoverable and makes the power shift visible |
| Permission panel | New story says the Agent appears automatically after the steps are collected | Remove the blocking panel from the playable route | The page remains a sanitized authored demo and no real external action is performed |

## State sequence

```text
intro
  -> hunt (four sources + invulnerable high-damage Boss)
  -> root-reveal (four sources collected; Causality Blade awaits pickup)
  -> boss (weapon equipped; vulnerable low-damage Boss)
  -> loot (three Actionable Steps)
  -> dispatch
  -> running (paper Agent flies to the light)
  -> handled
```

## Visual rules

- Keep the existing ink-fantasy world, mineral black materials, and one amber causal accent.
- Source equipment must be readable from silhouette: watch pulse, calendar grid, note waveform, memory/code crystal.
- The unarmed Boss strike uses rust-red warning energy; the equipped fight shifts toward amber-gold causal energy.
- UI stays subordinate to the world. The Agent flight must remain visible instead of being covered by a dashboard panel.
