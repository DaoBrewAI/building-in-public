# Causal Raid Loop Handoff

## Current State

- Repository: `git@github.com:DaoBrewAI/building-in-public.git`
- Causal Raid branch policy: source lives on `main`; do not create a Causal Raid feature or deployment branch. Other Building in Public packages are untouched.
- Canonical source: `causal-raid` on `origin/main`.
- App: `/Users/yz/building-in-public/causal-raid`
- Checkpoint: source migration and GitHub Pages deployment from Building in Public.
- Public URL: `https://daobrewai.github.io/building-in-public/causal-raid/`
- Legacy compiled deployment: `https://github.com/DaoBrewAI/causal-raid`

## Delivered Product

The first release is a deterministic sanitized Demo Mode. It requires no login, extension, DaoBrew installation, account connection, or private runtime. Every visitor receives the same short authored raid.

The playable sequence is:

1. Hunt three recurring symptoms and recover source-shaped evidence.
2. Reveal a root-cause candidate without claiming that causality is already proven.
3. Break four Boss seals with a mid-fight phase break and finishing vacuum.
4. Recover five task-package items: Goal, Steps, Acceptance, Permission, and Route.
5. Approve one human permission gate.
6. Watch the paper Agent keep executing across three tool boundaries.
7. Receive the Artifact and end at `HANDLED · VERIFY PENDING`.

English is the default locale. The entire visible interface can switch to Chinese, including mobile hints and the final handled state.

## Verification Completed

```bash
cd /Users/yz/building-in-public/causal-raid
npm run typecheck
npm run build
npm run preview -- --port 4174
```

- Typecheck: pass.
- Production build: pass, 605 modules.
- Output: CSS 23.83 kB / 5.97 kB gzip; JS 1,233.63 kB / 338.00 kB gzip.
- Desktop: complete real-browser playthrough from English intro to Artifact, plus replay reset.
- Localization: English default and full Chinese switch verified in browser.
- Mobile: 760 x 900 intro, combat controls, loot labels/toast, and Chinese handled screen verified.
- Reduced motion: browser-emulated `prefers-reduced-motion: reduce` rendered correctly.
- Production preview: static `dist` loaded successfully with no runtime errors.
- Public deployment: HTTPS returned 200 without authentication; GitHub Pages status `built`.
- Integrity: public JS and CSS SHA-256 hashes match the fully playtested local production build.
- Public smoke test: English default, Chinese switch, raid entry, WebGL scene, and controls verified.
- Console: only an upstream `THREE.Clock` deprecation warning remains.

## Important Fixes From Live Play

- Fixed the broken-bridge boundary so a player who reaches the north limit can move back into the arena.
- Reset Boss defeat-vacuum and paper-Agent progress refs on replay.
- Delayed the fifth-loot transition so its pickup confirmation remains visible.
- Removed the conflicting second execution CTA; authorization now leads directly into automatic execution.
- Added contact-frame damage, short hit stop, Boss cooldown/shockwave, finishing vacuum, radial loot burst, and layered impact audio.
- Added a low-power mobile render tier and kept all five task labels visible on phones.
- Disabled production source maps.

## Honest Limitations

- The public build is an authored product metaphor, not a live private Agent trace.
- Connected Mode is deferred behind a localhost-only security boundary.
- Vite reports a large-chunk warning because the Three.js game bundle is 338.00 kB gzip.
- A custom domain and analytics are not configured.

## Next Step

Record the public raid and use the URL in the prepared X and Xiaohongshu copy. A later pass can add a custom domain or bespoke social preview card without changing the game build.

## Auto-Chain Permission

auto_chain_next_session: true
