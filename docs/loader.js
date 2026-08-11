'use strict';

/* Continium — loader « particules → logo ».
 *
 * Des centaines de particules surgissent des bords de l'écran, tracent une
 * pluie de comètes et convergent vers la forme exacte du logo (échantillonnée
 * depuis l'image), où elles forment un nuage vivant. Le titre s'écarte,
 * puis les particules explosent vers les bords et l'overlay s'efface.
 *
 * Conçu et développé par Malo Lemoine — github.com/lomamalo/continium
 */

(function () {
  var loader = document.getElementById('loader');
  if (!loader) return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    loader.remove();
    return;
  }

  var canvas = document.getElementById('loaderCanvas');
  var ctx = canvas.getContext('2d');

  var CONVERGE = 1250;   // ms : rassemblement des particules
  var FINAL_MS = 2000;   // ms : état final figé (logo + titre) avant l'explosion
  var BURST = 850;       // ms : explosion vers les bords

  var W = 0, H = 0, DPR = 1;
  var particles = [];
  var phase = 'spawn';
  var phaseStart = 0;
  var t0 = 0;
  var raf = 0;
  var box = 0, cx = 0, cy = 0;

  /* ---------------- canvas ---------------- */
  function resize() {
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * DPR);
    canvas.height = Math.round(H * DPR);
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    box = Math.min(Math.max(Math.min(W, H) * 0.24, 130), 220);
    cx = W / 2;
    cy = H / 2 - box / 2 - 46;
  }
  window.addEventListener('resize', function () { resize(); });
  resize();

  /* ---------------- sprites lumineux ---------------- */
  function makeSprite(rgb, size) {
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var g = c.getContext('2d');
    var grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    grad.addColorStop(0, 'rgba(' + rgb + ',1)');
    grad.addColorStop(0.35, 'rgba(' + rgb + ',0.5)');
    grad.addColorStop(1, 'rgba(' + rgb + ',0)');
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    return c;
  }
  var spriteAccent = makeSprite('100,255,218', 32);   // #64FFDA
  var spriteWhite = makeSprite('255,255,255', 32);

  /* ---------------- échantillonnage du logo ---------------- */
  function subsample(pts, max) {
    if (pts.length <= max) return pts;
    var step = pts.length / max;
    var out = [];
    for (var i = 0; i < max; i++) {
      var p = pts[Math.floor(i * step)];
      out.push([p[0] + (Math.random() - 0.5) * 0.02, p[1] + (Math.random() - 0.5) * 0.02]);
    }
    return out;
  }

  function sampleFrom(renderFn, max) {
    var s = 64;
    var c = document.createElement('canvas');
    c.width = c.height = s;
    var g = c.getContext('2d');
    g.clearRect(0, 0, s, s);
    renderFn(g, s);
    var d = g.getImageData(0, 0, s, s).data;
    var pts = [];
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        var i = (y * s + x) * 4;
        var a = d[i + 3];
        if (a < 60) continue;
        var luma = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
        if (a > 220 && luma < 85) continue;   // fond opaque sombre
        pts.push([(x + 0.5) / s, (y + 0.5) / s]);
      }
    }
    return pts.length >= max * 0.3 ? subsample(pts, max) : null;
  }

  // Forme de secours : un « C » dessiné (si l'image n'est pas disponible).
  function fallbackPoints(max) {
    var pts = sampleFrom(function (g, s) {
      g.fillStyle = '#64FFDA';
      g.font = '700 46px "DejaVu Sans Mono", monospace';
      g.textAlign = 'center';
      g.textBaseline = 'middle';
      g.fillText('C', s / 2, s / 2 + 2);
    }, max);
    return pts || [];
  }

  function logoPoints(max) {
    var img = new Image();
    var done = false;
    var points = [];
    img.onload = function () {
      var pts = sampleFrom(function (g, s) {
        g.drawImage(img, 0, 0, s, s);
      }, max);
      if (pts) {
        points = pts;
      } else {
        points = fallbackPoints(max);
      }
      done = true;
    };
    img.onerror = function () { done = true; points = fallbackPoints(max); };
    img.src = 'assets/continium.png';

    // Délai de sécurité : l'image locale est quasi instantanée ; si elle
    // tarde, on démarre sur la forme de secours sans bloquer l'animation.
    var started = false;
    var check = setInterval(function () {
      if (done) { clearInterval(check); if (!started) launch(points); }
    }, 16);
    setTimeout(function () {
      if (!done) {
        clearInterval(check);
        started = true;
        launch(fallbackPoints(max));
      }
    }, 350);
    return check; // (gardé vivant par la closure)
  }

  /* ---------------- particules ---------------- */
  function easeOut(t) { return 1 - Math.pow(1 - t, 3); }
  function easeIn(t) { return t * t; }

  function spawn(targets) {
    var count = targets.length;
    particles = [];
    for (var i = 0; i < count; i++) {
      var ang = Math.random() * Math.PI * 2;
      var rad = Math.hypot(W, H) * (0.35 + Math.random() * 0.65);
      var x = cx + Math.cos(ang) * rad;
      var y = cy + Math.sin(ang) * rad;
      var t = targets[i];
      particles.push({
        x: x, y: y, px: x, py: y,
        sx: x, sy: y,
        tx: cx + (t[0] - 0.5) * box * 1.04,
        ty: cy + (t[1] - 0.5) * box * 1.04,
        size: 1 + Math.random() * 1.6,
        base: 0,
        delay: Math.random() * 430,
        wig: Math.random() * Math.PI * 2,
        white: Math.random() < 0.18,
        dirX: 0, dirY: 0,
        alpha: 1
      });
    }
    for (var j = 0; j < particles.length; j++) {
      particles[j].base = particles[j].size;
    }
  }

  function burstDirs() {
    var reach = Math.min(Math.max(Math.hypot(W, H) * 0.22, 120), 420);
    for (var i = 0; i < particles.length; i++) {
      var p = particles[i];
      var ang = Math.atan2(p.ty - cy, p.tx - cx) + (Math.random() - 0.5) * 1.4;
      var dist = reach * (0.3 + Math.random() * 0.9);
      p.dirX = Math.cos(ang) * dist;
      p.dirY = Math.sin(ang) * dist;
    }
  }

  /* ---------------- phases ---------------- */
  function setPhase(name) {
    phase = name;
    phaseStart = performance.now() - t0;
    if (name === 'burst') burstDirs();
  }

  function step(now, dt) {
    var et = now - t0 - phaseStart;
    var t, e;

    for (var i = 0; i < particles.length; i++) {
      var p = particles[i];
      var tt = now - t0 - p.delay;
      if (tt < 0) { p.px = p.x; p.py = p.y; continue; }

      if (phase === 'spawn') {
        t = Math.min(1, tt / CONVERGE);
        e = easeOut(t);
        p.x = p.sx + (p.tx - p.sx) * e;
        p.y = p.sy + (p.ty - p.sy) * e;
      } else if (phase === 'hold') {
        // Le nuage respire légèrement autour de la forme finale.
        t = Math.min(1, tt / CONVERGE);
        e = easeOut(t);
        var wob = Math.sin(now * 0.003 + p.wig) * 0.7;
        var wob2 = Math.cos(now * 0.0023 + p.wig) * 0.7;
        p.x = p.sx + (p.tx - p.sx) * e + wob * t;
        p.y = p.sy + (p.ty - p.sy) * e + wob2 * t;
        p.size = p.base * (1 + Math.sin(now * 0.004 + p.wig) * 0.3);
      } else if (phase === 'burst') {
        t = Math.min(1, et / BURST);
        e = easeIn(t);
        p.x = p.tx + p.dirX * e;
        p.y = p.ty + p.dirY * e;
        p.alpha = 1 - t;
      }
    }
    void dt;
  }

  /* ---------------- rendu ---------------- */
  function draw(now) {
    ctx.clearRect(0, 0, W, H);

    // Traînées : un seul path pour toutes les particules.
    ctx.beginPath();
    for (var i = 0; i < particles.length; i++) {
      var p = particles[i];
      ctx.moveTo(p.px, p.py);
      ctx.lineTo(p.x, p.y);
    }
    ctx.strokeStyle = 'rgba(100,255,218,0.14)';
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.globalCompositeOperation = 'lighter';
    for (var j = 0; j < particles.length; j++) {
      var q = particles[j];
      var s = q.size * 3.2;
      ctx.globalAlpha = q.alpha;
      ctx.drawImage(q.white ? spriteWhite : spriteAccent, q.x - s / 2, q.y - s / 2, s, s);
    }
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';

    // Mise à jour des précédentes positions.
    for (var k = 0; k < particles.length; k++) {
      particles[k].px = particles[k].x;
      particles[k].py = particles[k].y;
    }
    void now;
  }

  /* ---------------- séquence ----------------
   * 0          -> converge : les particules dessinent le logo
   * +150ms    -> le titre se déploie (flou -> net, letter-spacing)
   *            (transitions du titre terminées ~+1350ms)
   * +1350ms   -> état final figé pendant FINAL_MS (2 s)
   *            (logo vivant + titre étalé)
   * +FINAL_MS -> explosion, l'overlay s'efface, la page apparaît
   */
  function launch(targets) {
    t0 = performance.now();
    spawn(targets);
    loader.classList.add('active');
    setPhase('spawn');

    setTimeout(function () {
      document.querySelector('.loader-text').classList.add('ready');
    }, CONVERGE + 150);

    setTimeout(function () { setPhase('hold'); }, CONVERGE);
    setTimeout(function () { setPhase('burst'); }, CONVERGE + 150 + 1200 + FINAL_MS);
    setTimeout(function () { loader.classList.add('hide'); }, CONVERGE + 150 + 1200 + FINAL_MS + 160);
    setTimeout(function () { cancelAnimationFrame(raf); loader.remove(); }, CONVERGE + 150 + 1200 + FINAL_MS + BURST + 700);

    var last = performance.now();
    (function loop(now) {
      var dt = Math.min(now - last, 50);
      last = now;
      step(now, dt);
      draw(now);
      raf = requestAnimationFrame(loop);
    })(last);
  }

  var count = Math.max(300, Math.min(2400, Math.round((W * H) / 800)));
  logoPoints(count);
})();
