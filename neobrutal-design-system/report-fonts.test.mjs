import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const reportPaths = process.argv.slice(2);
const reportPath = reportPaths[0] ?? fileURLToPath(new URL("./report.html", import.meta.url));
const html = readFileSync(reportPath, "utf8");
const graphifySource = html.match(/<template id="graphify-source">([\s\S]*?)<\/template>/)?.[1] ?? "";

for (const mirrorPath of reportPaths.slice(1)) {
  assert.equal(
    readFileSync(mirrorPath, "utf8"),
    html,
    `report mirror drifted from ${reportPath}: ${mirrorPath}`,
  );
}

assert.match(
  html,
  /--font-display:\s*"SF Mono",ui-monospace,Menlo,Consolas,"PingFang SC",monospace;/,
  "display text must mirror daobrew.ai's system-mono stack with a CJK glyph fallback",
);
assert.match(
  html,
  /--font-text:\s*var\(--font-display\);/,
  "body copy must share the display family",
);
assert.match(
  html,
  /--font-mono:\s*"SF Mono",ui-monospace,Menlo,Consolas,monospace;/,
  "data and controls must use the landing page's mono stack",
);
assert.match(
  html,
  /body\{[^}]*font-family:var\(--font-text\)/s,
  "the report implementation must render in the same family it documents",
);

for (const staleRule of [
  /--sans:/,
  /--kai:/,
  /var\(--sans\)/,
  /var\(--kai\)/,
  /PingFang 700 大标题/,
  /mono 只给数据/,
  /一族三声\+书/,
]) {
  assert.doesNotMatch(html, staleRule, `stale typography rule remains: ${staleRule}`);
}

assert.match(html, /一族三声/);
assert.match(html, /显 = mono 700/);
assert.match(html, /述 = mono 400/);
assert.match(html, /印 = mono 700/);
assert.match(graphifySource, /一族三声/);
assert.match(graphifySource, /SF Mono/);
assert.match(graphifySource, /PingFang SC/);

console.log(`Typography contract passed: ${[reportPath, ...reportPaths.slice(1)].join(", ")}`);
