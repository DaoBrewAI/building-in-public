# Causal Raid Loop Tracker

> Migration note (2026-08-16): the original delivery rows below record the first standalone deployment. Canonical source now lives at `causal-raid` in `DaoBrewAI/building-in-public`; the current play URL is `https://daobrewai.github.io/building-in-public/causal-raid/`.

## Status Legend

- `[ ]` not started
- `[~]` in progress
- `[x]` complete
- `[!]` blocked

## Checkpoint Checklist

- [x] Phase 0: Correct the concept and isolate the initial build without touching unrelated user changes; the delivered source now lives directly on `main`.
- [x] Phase 1A: Build the playable WebGL ink world and encounter actors.
- [x] Phase 1B: Build input, timing, audio, and Agent execution director.
- [x] Phase 1C: Build the full bilingual game shell, English default, and touch controls.
- [x] Phase 2: Integrate the raid and tune hit, Boss, loot, Agent, and Artifact feedback.
- [x] Phase 3: Complete desktop, mobile, replay, reduced-motion, copy, and runtime QA.
- [x] Phase 4: Produce and verify the static build and record the deployment gate.

## Dependency Graph

```text
Phase 0 -> [Phase 1A, Phase 1B, Phase 1C] -> Phase 2 -> Phase 3 -> Phase 4
```

## Phases

| Phase | Status | Goal | Verification | Result |
| --- | --- | --- | --- | --- |
| 0 | [x] | Same repo, isolated implementation scope | Git status and path inspection | Delivered under `apps/causal-raid` on `main`; unrelated user changes remain untouched |
| 1A | [x] | Ink world, player, symptoms, Boss, loot, Agent, Artifact | Typecheck, build, visual browser pass | Complete |
| 1B | [x] | Input, phase timing, layered sound, 10 Hz execution publishing | Full live interaction loop | Complete |
| 1C | [x] | Typed English/Chinese UI, English default, touch controls | Desktop and 760 x 900 DOM/visual QA | Complete |
| 2 | [x] | Product-aligned raid with authored hit and loot feedback | Three symptoms, Boss 4 to 0, 5/5 loot, permission, Agent, Artifact | Complete |
| 3 | [x] | Production, browser, responsive, replay, reduced-motion QA | Real desktop playthrough, mobile states, replay reset, emulated reduced motion | Complete |
| 4 | [x] | Static artifact and public deployment handoff | Exact `dist` bytes served publicly with no runtime errors | Live at `https://daobrewai.github.io/causal-raid/` |

## Current Next Action

Use the live URL for recording and campaign posts. A custom domain remains optional and is not required for the first public launch.

## Evidence Log

| Checkpoint | Verification Run | Result | Notes |
| --- | --- | --- | --- |
| Build | `npm run typecheck` | Pass | TypeScript 7 project build |
| Build | `npm run build` | Pass | 605 modules; CSS 23.83 kB / 5.97 kB gzip; JS 1,233.63 kB / 338.00 kB gzip |
| Desktop loop | Real browser from intro through replay | Pass | English default, Chinese toggle, three evidence locks, root candidate, Boss break, 5/5 loot, one authorization, automatic execution, `HANDLED · VERIFY PENDING` |
| Game feel | Live visual inspection | Pass | Contact-timed hit, hit stop, directional camera impulse, Boss shockwave, defeat vacuum, radial loot, pickup toast, paper Agent, Artifact return |
| Replay | `HUNT AGAIN`, then re-enter | Pass | position reset, evidence 0, Boss locks 4, loot empty, progress 0, Artifact false |
| Mobile | 760 x 900 browser viewport | Pass | English and Chinese, mobile hints, four distinct arrow controls, attack control, loot labels/toast, translated handled state |
| Accessibility | Emulated `prefers-reduced-motion: reduce` | Pass | Stable rendered intro and shortened scripted timing path |
| Static artifact | `npm run preview -- --port 4174` | Pass | `dist` loads at `/`, English default, WebGL scene renders, no browser errors |
| Public deployment | GitHub Pages build `1087300965` | Pass | Public HTTPS URL returns 200 without authentication |
| Deployed integrity | SHA-256 comparison of local and public JS/CSS | Pass | Both deployed asset hashes exactly match the fully playtested production build |
| Public browser smoke | Fresh browser at the live URL | Pass | English default, Chinese switch, raid entry, WebGL scene, and controls verified |
| Runtime | Browser warnings/errors | Pass with note | No errors; only upstream Three.js `THREE.Clock` deprecation warning |
| Live bug fix | Boundary escape regression | Pass | Changed bridge clamp from `-10.1` to `-9.95`; player can return from the boundary |

## Remaining Release Notes

- Vite reports one large Three.js bundle warning; the shipped payload is 338.00 kB gzip.
- Production source maps are disabled.
- The public deployment repository contains only compiled static assets.
