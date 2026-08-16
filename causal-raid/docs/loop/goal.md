# DaoBrew Causal Raid Goal

## Objective

Ship a public, no-login, no-install browser Boss Raid that anyone can finish in 60-90 seconds. The game must use cinematic ink-fantasy combat to make DaoBrew's product loop immediately understandable: reveal a root-cause candidate, break it into an actionable task package, approve an Agent route, watch the Agent run until an Artifact returns, and finish at `HANDLED · VERIFY PENDING`.

The default locale is English. Players can switch the complete game UI to Chinese at any time.

## Done When

- A production URL can be served as static files and opens without an account, extension, local runtime, or DaoBrew installation.
- A first-time player can move, attack, defeat three symptom enemies, reveal and defeat one Root Boss, collect five meaningful task items, authorize the package, watch Agent execution, and see the returned Artifact change the world.
- Every player receives the same sanitized authored story. The public build contains no private graph, biometric, meeting, or Agent-session data.
- Every core surface is available in English and Chinese from one locale dictionary, with English as the initial default.
- Combat and loot have authored game feel: readable anticipation, contact flash, short hit stop, camera impulse, ink debris, sound, Boss break, loot burst, pickup confirmation, and Artifact payoff.
- The product meaning remains legible during play: `FIND ROOT`, `PACKAGE TASK`, `ROUTE AGENT`, `RUN UNTIL ARTIFACT`, and `VERIFY PENDING` are visible outcomes, not a marketing explanation pasted beside a generic game.
- `npm run typecheck` and `npm run build` pass.
- Real browser QA completes the full loop on desktop and verifies a usable mobile-width layout, reduced-motion behavior, English default, and Chinese switching.
- The final handoff records the `main` commit, run commands, build result, browser evidence, deployment state, and any honest limitations.

## Non-Goals

- Do not build an MMO, open world, multiplayer system, procedural campaign, login system, inventory economy, or replay grind.
- Do not connect the public build to Neo's private DaoBrew graph or claim the authored Agent sequence is a live private trace.
- Do not copy characters, logos, environments, audio, models, textures, UI, or trade dress from Black Myth: Wukong, World of Warcraft, or another game. Learn only from silhouette, camera grammar, encounter pacing, hit feedback, and loot cadence.
- Do not use HyperFrames, old promo assets, video-runtime conventions, orbit metaphors, solar-system skins, or a dashboard shell.
- Do not deploy, publish, register a domain, or transmit data without Neo's explicit approval.
- Do not modify the parent repo's completed P6.5 loop or unrelated Swift, Oura, Watch, backend, and MCP work.

## Read First

- docs/loop/tracker.md
- docs/loop/constraints.md
- docs/loop/handoff.md
- ../../IMPLEMENTATION.md
- ../../src/game/contracts.ts
- ../../src/game/demo-world.ts
- ../../src/game/store.ts
