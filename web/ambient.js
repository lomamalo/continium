/* Particules d'ambiance : fins points accent qui montent lentement en
 * vacillant, en arriere-plan permanent du site. La scene est calee sur la
 * geometrie (w,h) a chaque resize ; le rendu est volontairement discret.
 * Respecte prefers-reduced-motion. */
(function () {
  "use strict";
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const canvas = document.createElement("canvas");
  canvas.id = "ambientCanvas";
  canvas.setAttribute("aria-hidden", "true");
  document.body.prepend(canvas);

  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  let W = 0, H = 0, dpr = 1;
  let particles = [];

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    const n = Math.max(14, Math.min(34, Math.round((W * H) / 32000)));
    const rnd = Math.random;
    particles = Array.from({ length: n }, () => ({
      x: rnd() * W,
      y: rnd() * H,
      r: 0.7 + rnd() * 1.8,
      vy: 3 + rnd() * 8,
      sway: 0.4 + rnd() * 1.2,
      freq: 0.5 + rnd() * 0.9,
      phase: rnd() * Math.PI * 2,
      alpha: 0.05 + rnd() * 0.12,
    }));
  }
  window.addEventListener("resize", resize);
  resize();

  let last = performance.now();
  function frame(now) {
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    const t = now / 1000;

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    for (const p of particles) {
      p.y -= p.vy * dt;
      p.x += Math.sin(t * p.freq + p.phase) * p.sway * dt * 0.5;
      if (p.y < -4) { p.y = H + 4; p.x = Math.random() * W; }
      if (p.x < -4) p.x = W + 4;
      if (p.x > W + 4) p.x = -4;
      const twinkle = 0.6 + 0.4 * Math.sin(t * 1.1 + p.phase * 2.7);
      const a = p.alpha * twinkle;
      const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, p.r * 3);
      g.addColorStop(0, `rgba(100,255,218,${a})`);
      g.addColorStop(0.5, `rgba(100,255,218,${a * 0.35})`);
      g.addColorStop(1, "rgba(100,255,218,0)");
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r * 3, 0, Math.PI * 2);
      ctx.fill();
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
