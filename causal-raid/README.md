# DaoBrew Causal Raid

A one-minute, full-screen WebGL raid that turns DaoBrew's causal task loop into something you can play.

DaoBrew can feel abstract. Causal Raid makes the idea easier to understand through action: collect evidence, reveal a root-cause candidate, assemble a task package, approve a route, and watch an artifact return to the world. More importantly, it is fun.

**[Play DaoBrew Causal Raid →](https://daobrewai.github.io/building-in-public/causal-raid/)**

No login or installation is required. The game supports English and Chinese, desktop and touch controls, and uses one sanitized story rather than private DaoBrew data.

## Run locally

```bash
npm ci
npm run dev
```

Production check:

```bash
npm run build
npm run preview
```

The authored Agent sequence is a product metaphor, not a live execution trace. The ending stays at `HANDLED · VERIFY PENDING`: one successful run does not prove the root cause forever.
