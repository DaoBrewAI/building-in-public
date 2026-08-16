# Causal Raid implementation note

## Goal frame

Ship a public, full-screen, playable 60-90 second browser game that makes DaoBrew's product loop legible through action: reveal a root-cause candidate, turn it into a task package, approve an agent route, and watch the returned artifact change the world. The complete interface defaults to English and can be switched to Chinese at any time.

Acceptance evidence:

- A new visitor can complete the shared story with keyboard, pointer, or touch controls.
- A visitor can play without installing DaoBrew, logging in, or connecting any account.
- The scene is a live WebGL world, not a rendered video or landing-page mockup.
- English and Chinese share one typed locale contract, with English as the initial locale.
- The end state is `HANDLED · VERIFY PENDING`, preserving causal uncertainty.
- `npm run build` passes and the production build can be served as static files.
- A browser QA pass proves the full interaction loop at desktop and mobile widths.

## Resolved decisions

- Repository: public `DaoBrewAI/building-in-public` Git repository.
- Causal Raid workflow: future changes, releases, and fixes land directly on `main`; do not create a Causal Raid feature or deployment branch. Unrelated branches are out of scope.
- App location: `causal-raid`.
- First release: deterministic, sanitized Demo Mode suitable for a public URL.
- Connected Mode: deferred until a localhost-only bridge can expose graph and agent state safely.
- Visual language: cinematic 3D ink-fantasy action game. No space scene, orbit metaphor, dashboard shell, or HyperFrames runtime.
- Design dials: variance 9, motion 10, density 5.
- Encounter references: learn from premium action-RPG anticipation, contact, stagger, phase break, and loot cadence without copying protected assets or recognizable trade dress.

## Truth boundaries

- Enemies represent unresolved recurring loops, not tasks.
- Defeating the Boss arms an intervention package; it does not prove settled causality.
- Agent execution in Demo Mode is an authored simulation and must not be presented as a live private trace.
- Real private graph data must never be embedded in the public build.

## Deferred connected-mode unknowns

| Item | Reversible default | Later discriminator |
| --- | --- | --- |
| Browser-to-runtime transport | No live transport in public Demo Mode | Local bridge threat model and contract review |
| General task decomposition | Sanitized five-part package in the demo | Backend task package schema with steps and acceptance |
| Agent progress events | Authored execution beats | Persisted runtime event stream |
| Hosting target | GitHub Pages under `/building-in-public/causal-raid/` | Custom-domain decision |
