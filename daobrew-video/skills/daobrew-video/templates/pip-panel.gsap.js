/* daobrew-video — PiP overlay timeline tweens
 *
 * Append into the composition's timeline <script>, AFTER the timeline `tl` is created.
 * Fill the PIPS array with one entry per overlay: { sel, inAt, outAt }.
 * The per-panel video element should carry its own data-start / data-duration / data-track-index
 * matching inAt and the asset's natural duration (NEVER trim the asset — full motion always).
 */
const PIPS = [
  // { sel: "#pip-sentinel", inAt: 136.0, outAt: 160.4 },
  // { sel: "#pip-breath",   inAt: 143.0, outAt: 151.8 },
  // { sel: "#pip-mcp",      inAt: 172.6, outAt: 184.1 },
  // { sel: "#pip-b2b",      inAt: 185.0, outAt: 198.5 },
];
PIPS.forEach(function (p) {
  tl.fromTo(p.sel,
    { opacity: 0, scale: 0.96, y: -6 },
    { opacity: 1, scale: 1,    y: 0, duration: 0.7, ease: "power2.out" }, p.inAt);
  tl.to(p.sel,
    { opacity: 0, scale: 0.99, duration: 0.5, ease: "power2.inOut" }, p.outAt);
});
