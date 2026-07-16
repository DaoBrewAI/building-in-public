#!/usr/bin/env node
/**
 * status-provenance.mjs — derive the two-axis status markers for a status-truth doc.
 *
 * The producer does NOT hand-author the pills. This script decides each row's
 * code-state and whether it is a stale-build, from git ancestry alone.
 *
 * Usage:
 *   node status-provenance.mjs --repo <path> --running <sha> \
 *        --claims '[{"id":"A3","label":"...","sha":"5740587","tests":"15/15","target":"main"}]'
 *   node status-provenance.mjs --repo <path> --running <sha> --claims-file claims.json
 *
 * Per claim fields:
 *   id        (required)  short tag shown on the row
 *   label     (required)  human description
 *   sha       (required)  the commit that INTRODUCED the behavior (feature-SHA)
 *   tests     (optional)  raw pass/fail counts, e.g. "15/15" or "10 pass / 0 fail"
 *   target    (optional)  branch that means "merged" (default: main)
 *   witnessed (optional)  artifact record {type,path_or_quote,captured_against_sha,timestamp}
 *
 * Emits JSON to stdout: per row { id, label, codeState, evidence, color, reason, tests, witnessed }
 * codeState ∈ authored | merged | built
 * evidence  ∈ none | tests-green | witnessed-live | stale-build
 * color     ∈ grey | blue | amber | green
 *
 * The color law is enforced here so the HTML template only renders what this returns.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

function arg(name, fallback = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const repo = arg("repo", process.cwd());
const running = arg("running"); // running build SHA (may be undefined → caps evidence)
const claimsRaw = arg("claims");
const claimsFile = arg("claims-file");

if (!claimsRaw && !claimsFile) {
  console.error("error: provide --claims '<json>' or --claims-file <path>");
  process.exit(2);
}
let claims;
try {
  claims = JSON.parse(claimsRaw ?? readFileSync(claimsFile, "utf8"));
} catch (e) {
  console.error(`error: claims JSON did not parse — ${e.message}`);
  process.exit(2);
}
if (!Array.isArray(claims)) {
  console.error("error: claims must be a JSON array");
  process.exit(2);
}

function git(args) {
  return execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
}
// true if ancestor is an ancestor of (or equal to) descendant
function isAncestor(ancestor, descendant) {
  if (!ancestor || !descendant) return false;
  try {
    execFileSync("git", ["-C", repo, "merge-base", "--is-ancestor", ancestor, descendant], {
      stdio: "ignore",
    });
    return true; // exit 0
  } catch {
    return false; // exit 1 (not ancestor) or bad rev
  }
}
function shaExists(sha) {
  try {
    git(["cat-file", "-e", `${sha}^{commit}`]);
    return true;
  } catch {
    return false;
  }
}
function short(sha) {
  try {
    return git(["rev-parse", "--short", sha]);
  } catch {
    return String(sha).slice(0, 8);
  }
}

const rows = claims.map((c) => {
  const id = c.id ?? "?";
  const label = c.label ?? "";
  const sha = c.sha;
  const target = c.target ?? "main";
  const tests = c.tests ?? null;
  const witnessed = c.witnessed ?? null;

  // No feature-SHA ⇒ not a claim. Surface as planned so the producer must move it out.
  if (!sha) {
    return { id, label, codeState: "planned", evidence: "none", color: "grey",
      reason: "no feature-SHA — this is planned, not a status claim", tests, witnessed };
  }
  if (!shaExists(sha)) {
    return { id, label, codeState: "unknown", evidence: "none", color: "grey",
      reason: `feature-SHA ${short(sha)} not found in repo`, tests, witnessed };
  }

  // --- Axis A: code state ---
  let codeState = "authored";
  let mergedInTarget = false;
  try {
    mergedInTarget = isAncestor(sha, target);
  } catch { /* target may not exist */ }
  if (mergedInTarget) codeState = "merged";

  const inRunning = running ? isAncestor(sha, running) : false;
  if (inRunning) codeState = "built";

  // --- Axis B: evidence + color law ---
  let evidence = "none";
  let color = mergedInTarget ? "blue" : "grey";
  let reason = mergedInTarget ? "merged, not witnessed live" : "authored on a branch";

  if (tests) { evidence = "tests-green"; }

  // Stale-build overrides any witnessed claim.
  const claimsWitnessed = witnessed && witnessed.captured_against_sha;
  if (running && !inRunning) {
    evidence = "stale-build";
    color = "amber";
    reason = `running ${short(running)} · feature landed ${short(sha)} — not in the running build`;
  } else if (claimsWitnessed) {
    // Witnessed only counts if the artifact was captured against the running build.
    const matches = running && isAncestor(sha, running) &&
      isAncestor(witnessed.captured_against_sha, running) &&
      isAncestor(running, witnessed.captured_against_sha); // same commit both ways ⇒ equal-ish
    // Looser, robust check: the artifact's SHA must itself contain the feature.
    const artifactContainsFeature = isAncestor(sha, witnessed.captured_against_sha);
    if (inRunning && artifactContainsFeature) {
      evidence = "witnessed-live";
      color = "green";
      reason = `witnessed on ${short(witnessed.captured_against_sha)} (${witnessed.type})`;
    } else {
      // Artifact exists but doesn't clear the bar → do not go green.
      reason = inRunning
        ? `artifact ${short(witnessed.captured_against_sha)} does not contain feature ${short(sha)}`
        : reason;
    }
  }

  return { id, label, codeState, evidence, color, reason, tests, witnessed };
});

const witnessedCount = rows.filter((r) => r.color === "green").length;
const amber = rows.filter((r) => r.color === "amber").length;
const blue = rows.filter((r) => r.color === "blue").length;

const out = {
  running: running ? short(running) : null,
  summary: { total: rows.length, green: witnessedCount, amber, blue,
    footer: `${witnessedCount} of ${rows.length} witnessed live${running ? ` on build ${short(running)}` : ""}; ${blue} merged-but-unwitnessed, ${amber} stale-build.` },
  rows,
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
