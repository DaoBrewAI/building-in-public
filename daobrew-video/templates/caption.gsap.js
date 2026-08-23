/* daobrew-video — caption timeline loop
 *
 * Append into the composition's timeline <script>, AFTER the timeline `tl` is created.
 * Requires <div id="cap-layer"></div> in the root composition and a window.__CAPS array
 * of { t, s, e } for English-only captions or { zh, en, s, e } for bilingual captions —
 * typically loaded from captions.data.js.
 *
 * Source caption TEXT from the user's polished script. Use ASR (hyperframes transcribe)
 * to anchor `s` / `e` times only. Where the recording improvises away from the script,
 * follow the script wording.
 */
const capLayer = document.getElementById("cap-layer");
(window.__CAPS || []).forEach(function (c) {
  const wrap = document.createElement("div");
  wrap.className = "cap"; wrap.style.opacity = "0";
  const inner = document.createElement("div");
  inner.className = "cap-inner";
  if (c.zh || c.en) {
    inner.classList.add("cap-bilingual");
    if (c.zh) {
      const zh = document.createElement("div");
      zh.className = "cap-zh"; zh.textContent = c.zh;
      inner.appendChild(zh);
    }
    if (c.en) {
      const en = document.createElement("div");
      en.className = "cap-en"; en.textContent = c.en;
      inner.appendChild(en);
    }
  } else {
    inner.classList.add("cap-single"); inner.textContent = c.t;
  }
  wrap.appendChild(inner); capLayer.appendChild(wrap);
  const outAt = Math.max(c.s + 0.25, c.e - 0.22);
  tl.fromTo(wrap, { opacity: 0, y: 26 }, { opacity: 1, y: 0, duration: 0.3, ease: "power3.out" }, c.s);
  tl.to(wrap, { opacity: 0, y: -14, duration: 0.22, ease: "power2.in" }, outAt);
});
