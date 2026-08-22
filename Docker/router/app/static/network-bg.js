// Fondo animado: nodos conectados por líneas, al estilo de un diagrama de
// red. Sin librerías externas (canvas + JS puro) porque esta página se
// sirve a clientes sin autenticar, que aún no tienen salida a Internet.
(function () {
  "use strict";

  var canvas = document.getElementById("net-bg");
  if (!canvas || !canvas.getContext) return;

  var reduceMotion = window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var ctx = canvas.getContext("2d");
  var dpr = Math.min(window.devicePixelRatio || 1, 2);
  var W = 0, H = 0, nodes = [], rafId = null;

  // Varios matices (no un solo color): azul, índigo, cian, violeta --
  // la misma familia del acento del botón, pero con variedad real.
  var COLORS = ["#38bdf8", "#6366f1", "#22d3ee", "#a78bfa"];
  var LINK_DIST = 130;

  function resize() {
    W = canvas.width = Math.round(canvas.clientWidth * dpr);
    H = canvas.height = Math.round(canvas.clientHeight * dpr);
  }

  function initNodes() {
    var area = canvas.clientWidth * canvas.clientHeight;
    var count = Math.max(18, Math.min(60, Math.round(area / 16000)));
    nodes = [];
    for (var i = 0; i < count; i++) {
      nodes.push({
        x: Math.random() * W,
        y: Math.random() * H,
        vx: (Math.random() - 0.5) * 0.35 * dpr,
        vy: (Math.random() - 0.5) * 0.35 * dpr,
        r: (Math.random() * 1.3 + 1) * dpr,
        color: COLORS[i % COLORS.length],
      });
    }
  }

  function frame() {
    ctx.clearRect(0, 0, W, H);
    var linkDist = LINK_DIST * dpr;

    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      n.x += n.vx;
      n.y += n.vy;
      if (n.x <= 0 || n.x >= W) n.vx *= -1;
      if (n.y <= 0 || n.y >= H) n.vy *= -1;
    }

    for (var a = 0; a < nodes.length; a++) {
      for (var b = a + 1; b < nodes.length; b++) {
        var n1 = nodes[a], n2 = nodes[b];
        var dx = n1.x - n2.x, dy = n1.y - n2.y;
        var dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < linkDist) {
          ctx.globalAlpha = (1 - dist / linkDist) * 0.32;
          ctx.strokeStyle = n1.color;
          ctx.lineWidth = dpr;
          ctx.beginPath();
          ctx.moveTo(n1.x, n1.y);
          ctx.lineTo(n2.x, n2.y);
          ctx.stroke();
        }
      }
    }

    ctx.globalAlpha = 0.75;
    for (var k = 0; k < nodes.length; k++) {
      var nd = nodes[k];
      ctx.fillStyle = nd.color;
      ctx.beginPath();
      ctx.arc(nd.x, nd.y, nd.r, 0, Math.PI * 2);
      ctx.fill();
    }

    if (!reduceMotion) rafId = requestAnimationFrame(frame);
  }

  function start() {
    resize();
    initNodes();
    frame(); // si reduceMotion, dibuja un solo cuadro estático y se detiene
  }

  window.addEventListener("resize", function () {
    resize();
    initNodes();
  });

  document.addEventListener("visibilitychange", function () {
    // Pausa en segundo plano para no gastar batería sin necesidad.
    if (document.hidden) {
      if (rafId) cancelAnimationFrame(rafId);
      rafId = null;
    } else if (!reduceMotion && !rafId) {
      frame();
    }
  });

  start();
})();
