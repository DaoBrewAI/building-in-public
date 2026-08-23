/* daobrew-video — outro card timeline tweens
 *
 * Append into the composition's timeline <script>, AFTER the timeline `tl` is created
 * (`const tl = gsap.timeline({ paused: true });`).
 *
 * SET THE END CONSTANT BELOW to your composition's total duration in seconds.
 * The outro occupies roughly the final 4.7 seconds (END-4.7 .. END).
 */
const END = /* set this to your composition end time in seconds, e.g. */ 60;

// Override tagline from composition variables if the composition declared
// outro_l1 / outro_l2 (see outro-card.variables.json). Defaults come from the HTML.
(function () {
  if (window.__hyperframes && window.__hyperframes.getVariables) {
    var v = window.__hyperframes.getVariables();
    var l1 = document.getElementById("oc-l1");
    var l2 = document.getElementById("oc-l2");
    if (l1 && v.outro_l1) l1.textContent = v.outro_l1;
    if (l2 && v.outro_l2) l2.textContent = v.outro_l2;
  }
})();

// Six staggered tweens: fade footage out → reveal outro → icon/line1/line2/wordmark.
tl.to("#footage", { opacity: 0, duration: 0.9, ease: "power2.in" }, END - 4.7);
tl.fromTo("#outro", { opacity: 0 }, { opacity: 1, duration: 0.7, ease: "power2.out" }, END - 4.4);
tl.fromTo("#oc-icon", { opacity: 0, scale: 0.62, y: 22 }, { opacity: 1, scale: 1, y: 0, duration: 0.8, ease: "back.out(1.5)" }, END - 4.0);
tl.fromTo("#oc-l1",   { opacity: 0, y: 30 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }, END - 3.5);
tl.fromTo("#oc-l2",   { opacity: 0, y: 32, scale: 0.96 }, { opacity: 1, y: 0, scale: 1, duration: 0.6, ease: "back.out(1.3)" }, END - 3.2);
tl.fromTo("#oc-wm",   { opacity: 0 }, { opacity: 1, duration: 0.5, ease: "power2.out" }, END - 2.6);
