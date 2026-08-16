# Causal Raid Constraints

## Product Constraints

- Public visitors must not install DaoBrew, sign in, connect an account, or provide data.
- Every visitor plays the same short authored story. Default target duration is 60-90 seconds.
- English is the default locale. All core gameplay and state UI must have complete Chinese equivalents and a persistent in-game language switch.
- The Boss is an unresolved recurring loop. Tasks are the meaningful equipment dropped after the Boss breaks.
- The five drops must remain product-readable: Goal, Steps, Acceptance, Permission, and Route.
- Human authorization is a visible gate before Agent execution.
- The ending is `HANDLED · VERIFY PENDING`, never a claim that causality has been permanently proven.
- Game feel serves product comprehension. One polished encounter is preferable to more maps, enemies, menus, or systems.

## Visual And Interaction Constraints

- Visual language: original DaoBrew ink-fantasy, dark mineral neutrals, one amber-gold causal accent, strong silhouette and scale contrast.
- Inspiration from premium action RPGs is limited to camera, anticipation, contact, hit stop, enemy stagger, phase break, loot cadence, and environmental payoff. No borrowed game assets or recognizable imitation.
- Required Boss/loot feedback: anticipation cue, contact flash, 45-90 ms hit stop, restrained camera impulse, ink fragments, low-frequency impact sound, short defeat vacuum, radial loot burst, hover/pickup response, and a strong Artifact-return world change.
- No generic RPG health-bar skin over a dashboard. Evidence locks communicate encounter progress.
- No space setting, solar system, orbital data model, AI-purple glow, glass-card wall, or landing-page sections.
- Full-screen live WebGL is the product. Any cinematic path remains interruptible and is recorded from the real site.
- Keyboard/pointer and touch must both complete the authored loop.
- Respect `prefers-reduced-motion`; reduce duration and camera intensity without removing semantic state changes.

## Engineering Constraints

- Scope all game source to `causal-raid` and land approved changes directly on `main`.
- Keep the public build static and self-contained. Do not require a backend.
- Keep continuous movement and camera values out of React render state.
- Use one locale dictionary and typed translation keys. Do not fork the component tree by language.
- Avoid large textures and unnecessary dependencies. Prefer procedural geometry, shaders, synthesized sound, and instancing.
- Target smooth desktop play and a credible 30 fps low-power path. Cap device pixel ratio and provide reduced effects when needed.
- Run `npm run typecheck` and `npm run build` before browser QA.
- Use direct browser interaction to prove the actual game loop. A static screenshot is not sufficient.
- Do not touch unrelated files or the parent `docs/loop` contract.

## Safety And Truth Constraints

- The authored public Agent sequence must be described as Demo Mode, not a live trace.
- Do not embed private names, meetings, biometrics, graph nodes, credentials, local paths, or raw artifacts in the production bundle.
- Do not add arbitrary shell execution, prompt input, upload, or remote-control endpoints.
- Do not add a custom domain, analytics, authentication, private-data connection, or unrelated external upload without explicit approval.

## Efficiency Constraints

- Finish the complete vertical slice before adding optional polish.
- Use file-disjoint parallel lanes only where dependencies are explicit.
- Prefer one high-value visual refinement pass and one browser-driven correction pass. Do not churn aesthetics without observable evidence.
- Do not add systems that do not appear in the 60-90 second player journey.

## Git Constraints

- Preserve the original worktree and all pre-existing user changes.
- Causal Raid is maintained directly on `main`. Do not create a Causal Raid feature, pull-request, deployment, or Pages branch.
- Do not create, delete, rename, merge, or otherwise alter unrelated Building in Public branches.
- Push approved Causal Raid changes directly to `origin/main`; GitHub Pages deploys the production build from that same branch.
- Commit only after verification and only if Neo explicitly asks or the active loop handoff changes this gate.
- Do not push, merge, rewrite history, or deploy without explicit approval.

## Session Settings

- Any continuation session must request `model: "gpt-5.6-sol"`, `reasoning_effort: "ultra"`, and FAST mode via `service_tier: "priority"` when the session tool exposes those fields.
