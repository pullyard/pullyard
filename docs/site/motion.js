(function () {
  var root = document.documentElement;
  var reduceMQ = window.matchMedia("(prefers-reduced-motion: reduce)");
  var motion = !reduceMQ.matches && root.classList.contains("motion");
  var finePointer = window.matchMedia("(hover: hover) and (pointer: fine)").matches;
  var hasIO = "IntersectionObserver" in window;
  var SVGNS = "http://www.w3.org/2000/svg";
  var uid = 0;

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function ease(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
  function stage(p, a, b) { return ease(clamp((p - a) / (b - a), 0, 1)); }
  function smooth(t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
  function outCubic(t) { t = clamp(t, 0, 1); return 1 - Math.pow(1 - t, 3); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function damp(k, dt) { return 1 - Math.exp(-k * dt); }
  function docTop(el) { return el.getBoundingClientRect().top + window.scrollY; }
  var INTERACTIVE = "a,button,input,textarea,select,summary,label,video,[role=application],[tabindex]:not([tabindex='-1'])";

  function logoMarkup(opts) {
    var id = "pyl" + (++uid);
    var g = function (n, a, b, x2, y2, o2) {
      return '<linearGradient id="' + id + n + '" x1="0" y1="0" x2="' + x2 + '" y2="' + y2 + '"><stop offset="0" stop-color="' + a + '"/><stop offset="' + (o2 || 1) + '" stop-color="' + b + '"' + (n === "hl" ? ' stop-opacity="0"' : "") + "/></linearGradient>";
    };
    var s = '<svg class="logo-svg" viewBox="' + (opts.crop ? "150 370 750 500" : "100 100 824 824") + '" aria-hidden="true" focusable="false"><defs>' +
      g("bg", "#26324A", "#030712", 0, 1) +
      '<linearGradient id="' + id + 'hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".18"/><stop offset=".45" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>' +
      g("hull", "#FB7185", "#D61F4E", 0, 1) +
      '<linearGradient id="' + id + 'sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0EA5E9" stop-opacity=".22"/><stop offset="1" stop-color="#0EA5E9" stop-opacity="0"/></linearGradient>' +
      g("b1", "#A78BFA", "#C4B5FD", 1, 0) + g("b2", "#38BDF8", "#7DD3FC", 1, 0) +
      '<clipPath id="' + id + 'sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>';
    if (opts.bg) {
      s += '<g class="lg-bg"><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#' + id + 'bg)"/><rect x="100" y="700" width="824" height="224" fill="url(#' + id + 'sea)" clip-path="url(#' + id + 'sq)"/></g>';
    }
    s += '<g class="lg-mark">' +
      '<g fill="none" stroke-linecap="round">' +
      '<circle class="lg-nodeA" cx="206" cy="500" r="34" stroke="#A78BFA" stroke-width="18" pathLength="1"/>' +
      '<circle class="lg-nodeB" cx="206" cy="772" r="34" stroke="#38BDF8" stroke-width="18" pathLength="1"/>' +
      '<path class="lg-curveA" d="M240 500 C392 500 420 636 520 636" stroke="url(#' + id + 'b1)" stroke-width="24" pathLength="1"/>' +
      '<path class="lg-curveB" d="M240 772 C392 772 420 636 520 636" stroke="url(#' + id + 'b2)" stroke-width="24" pathLength="1"/>' +
      "</g>" +
      '<g class="lg-boat"><g class="lg-bob">' +
      '<g class="lg-hullfill"><path d="M470 566 L866 566 L800 728 L540 728 Z" fill="url(#' + id + 'hull)"/><path d="M470 566 L866 566 L857 590 L480 590 Z" fill="#FECDD3"/><circle cx="770" cy="642" r="15" fill="#FFE4E6" opacity=".9"/></g>' +
      '<path class="lg-hullline" d="M470 566 L866 566 L800 728 L540 728 Z" fill="none" stroke="#FB7185" stroke-width="14" stroke-linejoin="round" stroke-linecap="round" pathLength="1"/>' +
      '<g class="lg-cabin"><rect x="702" y="392" width="40" height="86" rx="8" fill="#E2E8F0"/><rect x="702" y="392" width="40" height="20" rx="6" fill="#FB7185"/><rect x="584" y="462" width="176" height="104" rx="16" fill="#F8FAFC"/><rect x="584" y="540" width="176" height="26" fill="#E2E8F0"/><rect x="610" y="488" width="38" height="34" rx="8" fill="#1E293B"/><rect x="664" y="488" width="38" height="34" rx="8" fill="#1E293B"/></g>' +
      "</g></g>" +
      '<g class="lg-waves" fill="none" stroke="#7DD3FC" stroke-linecap="round">' +
      '<path class="lg-wave1" d="M560 786 C620 770 660 802 720 786 C780 770 820 770 870 786" stroke-opacity=".55" stroke-width="12" pathLength="1"/>' +
      '<path class="lg-wave2" d="M600 836 C650 822 690 848 740 836 C790 824 820 822 850 836" stroke-opacity=".32" stroke-width="10" pathLength="1"/>' +
      "</g></g>";
    if (opts.bg) {
      s += '<g class="lg-hl"><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#' + id + 'hl)"/><rect x="101.5" y="101.5" width="821" height="821" rx="184" fill="none" stroke="#FFFFFF" stroke-opacity=".10" stroke-width="3"/></g>';
    }
    return s + "</svg>";
  }

  function Logo(host, opts) {
    host.innerHTML = logoMarkup(opts || {});
    var svg = host.querySelector("svg"), q = function (c) { return svg.querySelector(c); };
    this.svg = svg;
    this.bg = [q(".lg-bg"), q(".lg-hl")].filter(Boolean);
    this.nodes = [q(".lg-nodeA"), q(".lg-nodeB")];
    this.curves = [q(".lg-curveA"), q(".lg-curveB")];
    this.hullLine = q(".lg-hullline");
    this.hullFill = q(".lg-hullfill");
    this.cabin = q(".lg-cabin");
    this.wave1 = q(".lg-wave1");
    this.wave2 = q(".lg-wave2");
    this.boat = q(".lg-boat");
    [this.nodes[0], this.nodes[1], this.curves[0], this.curves[1], this.hullLine, this.wave1, this.wave2].forEach(function (el) { el.style.strokeDasharray = "1 1"; });
    this.p = -1;
    this.raf = 0;
  }
  function dash(el, v) {
    el.style.strokeDashoffset = String(1 - v);
    el.style.opacity = v > 0.0005 ? "" : "0";
  }
  Logo.prototype.set = function (p) {
    if (p === this.p) return;
    this.p = p;
    var n = stage(p, 0, 0.22), c = stage(p, 0.14, 0.48), hl = stage(p, 0.40, 0.68), hf = stage(p, 0.58, 0.78), cb = stage(p, 0.66, 0.86), w = stage(p, 0.74, 1);
    dash(this.nodes[0], n); dash(this.nodes[1], n);
    dash(this.curves[0], c); dash(this.curves[1], c);
    this.hullLine.style.strokeDashoffset = String(1 - hl);
    this.hullLine.style.opacity = hl > 0.0005 ? String(1 - hf * 0.85) : "0";
    this.hullFill.style.opacity = String(hf);
    this.cabin.setAttribute("transform", "translate(0 566) scale(1 " + (0.6 + 0.4 * cb).toFixed(4) + ") translate(0 -566)");
    this.cabin.style.opacity = String(cb);
    dash(this.wave1, w);
    dash(this.wave2, Math.max(0, w - 0.15) / 0.85);
  };
  Logo.prototype.showBg = function (on) {
    this.bg.forEach(function (el) { el.style.opacity = on ? "1" : "0"; });
  };
  Logo.prototype.draw = function (ms, done) {
    var self = this, t0 = 0;
    cancelAnimationFrame(this.raf);
    this.set(0);
    function tick(now) {
      if (!t0) t0 = now;
      var p = Math.min(1, (now - t0) / ms);
      self.set(p);
      if (p < 1) self.raf = requestAnimationFrame(tick);
      else if (done) done();
    }
    this.raf = requestAnimationFrame(tick);
  };

  function wrapWords(el, cls, onWord) {
    (function walk(node) {
      Array.prototype.slice.call(node.childNodes).forEach(function (child) {
        if (child.nodeType === 3) {
          var parts = child.textContent.split(/(\s+)/), frag = document.createDocumentFragment();
          parts.forEach(function (part) {
            if (!part) return;
            if (/^\s+$/.test(part)) { frag.appendChild(document.createTextNode(" ")); return; }
            var w = document.createElement("span");
            w.className = cls;
            w.textContent = part;
            frag.appendChild(onWord ? onWord(w) : w);
          });
          node.replaceChild(frag, child);
        } else if (child.nodeType === 1 && child.tagName !== "BR") {
          walk(child);
        }
      });
    })(el);
  }

  function splitWords(el, base) {
    if (!el || el.classList.contains("wsplit")) return;
    var i = 0;
    wrapWords(el, "wi", function (wi) {
      var w = document.createElement("span");
      w.className = "w";
      wi.style.setProperty("--i", i++);
      w.appendChild(wi);
      return w;
    });
    if (base) el.style.setProperty("--d", base);
    el.classList.add("wsplit");
  }

  function numberLines(el) {
    var top = null, ln = -1;
    el.querySelectorAll(".lw").forEach(function (w) {
      var t = w.offsetTop;
      if (top === null || t > top + 4) { ln++; top = t; }
      w.style.setProperty("--ln", ln);
    });
  }

  var scenes = [], actors = [], ticking = false, dirty = true, vh = window.innerHeight, vw = window.innerWidth;
  var sy = window.scrollY, lastT = 0, glide = null, onScrollHooks = [];
  var SMOOTH = 10;
  function requestFrame() { if (!ticking) { ticking = true; requestAnimationFrame(frame); } }
  function invalidate() { dirty = true; requestFrame(); }
  function wake(a) { if (actors.indexOf(a) < 0) actors.push(a); requestFrame(); }
  function frame(now) {
    ticking = false;
    var dt = lastT ? clamp((now - lastT) / 1000, 0.001, 0.064) : 1 / 60;
    lastT = now;
    if (glide) glide(now);
    if (dirty) {
      dirty = false;
      vh = window.innerHeight;
      vw = window.innerWidth;
      for (var m = 0; m < scenes.length; m++) if (scenes[m].measure) scenes[m].measure();
    }
    var y = window.scrollY;
    if (motion) {
      var cap = vh * 2.5;
      if (y - sy > cap) sy = y - cap; else if (sy - y > cap) sy = y + cap;
      sy += (y - sy) * damp(SMOOTH, dt);
      if (Math.abs(y - sy) < 0.3) sy = y;
    } else {
      sy = y;
    }
    for (var i = 0; i < scenes.length; i++) if (scenes[i].on) scenes[i].update(sy, y, dt);
    for (var j = actors.length - 1; j >= 0; j--) if (!actors[j].tick(dt, now, y)) actors.splice(j, 1);
    if (sy !== y || glide || actors.length) requestFrame(); else lastT = 0;
  }
  function watch(scene, el, margin) {
    scenes.push(scene);
    if (!hasIO || !el) { scene.on = true; return; }
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { scene.on = e.isIntersecting; if (scene.toggle) scene.toggle(e.isIntersecting); });
      requestFrame();
    }, { rootMargin: margin || "0px" }).observe(el);
  }
  window.addEventListener("scroll", function () {
    requestFrame();
    for (var i = 0; i < onScrollHooks.length; i++) onScrollHooks[i]();
  }, { passive: true });
  window.addEventListener("resize", invalidate);
  if ("ResizeObserver" in window) new ResizeObserver(invalidate).observe(document.body);
  document.addEventListener("visibilitychange", function () { root.classList.toggle("anim-paused", document.hidden); });

  function stopGlide() {
    if (!glide) return;
    glide = null;
    root.style.scrollBehavior = "";
  }
  function glideTo(top, done) {
    var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    top = clamp(Math.round(top), 0, max);
    var from = window.scrollY, d = top - from;
    stopGlide();
    if (!motion || Math.abs(d) < 2) {
      root.style.scrollBehavior = "auto";
      window.scrollTo(0, top);
      root.style.scrollBehavior = "";
      if (done) done();
      return;
    }
    var dur = clamp(300 + Math.sqrt(Math.abs(d)) * 13, 420, 1150), t0 = 0;
    root.style.scrollBehavior = "auto";
    glide = function (now) {
      if (!t0) t0 = now;
      var t = clamp((now - t0) / dur, 0, 1);
      window.scrollTo(0, from + d * ease(t));
      if (t >= 1) { stopGlide(); if (done) done(); }
    };
    requestFrame();
  }
  function sailTo(top) {
    var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    top = clamp(Math.round(top), 0, max);
    var from = window.scrollY, d = top - from;
    stopGlide();
    if (!motion || Math.abs(d) < 2) {
      root.style.scrollBehavior = "auto";
      window.scrollTo(0, top);
      root.style.scrollBehavior = "";
      return;
    }
    var dur = clamp(Math.abs(d) / 0.4, 3000, 40000), t0 = 0;
    root.style.scrollBehavior = "auto";
    glide = function (now) {
      if (!t0) t0 = now;
      var t = clamp((now - t0) / dur, 0, 1);
      window.scrollTo(0, from + d * (0.5 - Math.cos(Math.PI * t) / 2));
      if (t >= 1) stopGlide();
    };
    glide.voyage = true;
    requestFrame();
  }
  var sailingAtDown = false;
  ["pointerdown", "keydown"].forEach(function (ev) { document.addEventListener(ev, function () { sailingAtDown = !!(glide && glide.voyage); }, true); });
  ["wheel", "touchstart", "keydown", "mousedown"].forEach(function (ev) { window.addEventListener(ev, stopGlide, { passive: true }); });
  function navOffset() {
    var h = document.querySelector(".site-header");
    return (h ? h.offsetHeight : 64) + 16;
  }
  function focusTarget(el) {
    if (!el.hasAttribute("tabindex") && !/^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY)$/.test(el.tagName)) el.setAttribute("tabindex", "-1");
    try { el.focus({ preventScroll: true }); } catch (e) {}
  }
  window.PullYardGlide = function (el, done) {
    glideTo(docTop(el) - navOffset(), function () { if (done) done(); });
  };
  document.addEventListener("click", function (e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var a = e.target.closest && e.target.closest('a[href^="#"]');
    if (!a || a.classList.contains("skip")) return;
    var id = decodeURIComponent(a.getAttribute("href").slice(1));
    var el = id && document.getElementById(id);
    if (!el) return;
    e.preventDefault();
    glideTo(id === "main" ? 0 : docTop(el) - navOffset(), function () { focusTarget(el); });
    if (history.pushState) history.pushState(null, "", "#" + id);
  });

  var navLogo = null, brandImg = document.querySelector(".brand img");
  if (motion && brandImg) {
    var mark = document.createElement("span");
    mark.className = "brand-mark";
    mark.setAttribute("aria-hidden", "true");
    brandImg.parentNode.replaceChild(mark, brandImg);
    navLogo = new Logo(mark, { bg: true });
    navLogo.set(1);
  }

  root.classList.add("intro-go");
  var heroHost = document.querySelector("[data-hero-logo]");
  var heroBg = document.querySelector(".hero-bg");
  if (motion && heroHost) {
    var heroLogo = new Logo(heroHost, { bg: true });
    heroLogo.showBg(false);
    heroLogo.set(0);
    heroHost.classList.add("is-ready");
    setTimeout(function () {
      heroLogo.draw(1700, function () { heroLogo.svg.classList.add("idle"); });
    }, 80);
    setTimeout(function () { heroLogo.showBg(true); heroHost.classList.add("bg-in"); }, 1540);

    var navDrawn = true, heroInit = false, heroTop = 0, heroH = 0, lastHero = "";
    watch({
      measure: function () {
        var t = heroHost.style.transform;
        heroHost.style.transform = "";
        heroTop = docTop(heroHost);
        heroH = heroHost.offsetHeight;
        heroHost.style.transform = t;
      },
      update: function (y) {
        var span = Math.max(1, heroTop + heroH * 0.6);
        var p = clamp(y / span, 0, 1);
        var e = smooth(p);
        var op = (1 - smooth((p - 0.35) / 0.6)).toFixed(3);
        var css = "translate3d(0," + (y * 0.32).toFixed(1) + "px,0) scale(" + (1 - 0.3 * e).toFixed(4) + ")";
        if (css + op !== lastHero) {
          lastHero = css + op;
          heroHost.style.transform = css;
          heroHost.style.opacity = op;
          heroLogo.boat.setAttribute("transform", "translate(" + (16 * e).toFixed(2) + " " + (-3 * e).toFixed(2) + ")");
        }
        if (!heroInit) { heroInit = true; navDrawn = p > 0.95; }
        if (navLogo) {
          if (p >= 0.97 && !navDrawn) { navDrawn = true; navLogo.draw(1100); }
          else if (p < 0.25 && navDrawn) navDrawn = false;
        }
      },
      toggle: function (vis) { heroLogo.svg.classList.toggle("is-offscreen", !vis); }
    }, heroHost, "120px 0px 120px 0px");
  }

  if (heroBg && hasIO) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { heroBg.classList.toggle("is-paused", !e.isIntersecting); });
    }).observe(heroBg);
  }

  var tour = document.querySelector(".tour-video");
  if (motion && tour) {
    var tourTop = 0, lastTour = "";
    watch({
      measure: function () {
        var t = tour.style.transform;
        tour.style.transform = "";
        tourTop = docTop(tour);
        tour.style.transform = t;
      },
      update: function (y) {
        var rel = tourTop - y;
        var e = outCubic((vh - rel) / (vh * 0.78));
        var css = "perspective(1600px) rotateX(" + ((1 - e) * 18).toFixed(2) + "deg) scale(" + (0.92 + 0.08 * e).toFixed(4) + ")";
        if (css !== lastTour) { lastTour = css; tour.style.transform = css; }
      }
    }, tour, "200px 0px 200px 0px");
  }

  document.querySelectorAll("main h2").forEach(function (h) { if (motion) splitWords(h); });

  if (motion) {
    document.querySelectorAll(".reveal .shot-img, .story-step figure img").forEach(function (img) {
      img.classList.add("wipe");
      img.addEventListener("transitionend", function done(e) {
        if (e.propertyName !== "clip-path") return;
        img.classList.add("is-sharp");
        img.removeEventListener("transitionend", done);
      });
    });
  }

  document.querySelectorAll(".grid .card").forEach(function (card, i) {
    card.style.setProperty("--i", i % 3 + Math.floor(i / 3));
    if (!motion || !finePointer) return;
    var st = { rx: 0, ry: 0, trx: 0, try: 0, mx: 50, my: 0, tmx: 50, tmy: 0, rect: null, key: "" };
    var actor = {
      tick: function (dt) {
        var f = damp(11, dt), g = damp(16, dt);
        st.rx += (st.trx - st.rx) * f;
        st.ry += (st.try - st.ry) * f;
        st.mx += (st.tmx - st.mx) * g;
        st.my += (st.tmy - st.my) * g;
        var done = Math.abs(st.trx - st.rx) < 0.01 && Math.abs(st.try - st.ry) < 0.01 && Math.abs(st.tmx - st.mx) < 0.05 && Math.abs(st.tmy - st.my) < 0.05;
        if (done) { st.rx = st.trx; st.ry = st.try; st.mx = st.tmx; st.my = st.tmy; }
        var still = Math.abs(st.rx) < 0.005 && Math.abs(st.ry) < 0.005;
        var css = still ? "" : "perspective(900px) rotateX(" + st.rx.toFixed(3) + "deg) rotateY(" + st.ry.toFixed(3) + "deg) translateZ(0)";
        if (css !== st.key) { st.key = css; card.style.transform = css; }
        card.style.setProperty("--mx", st.mx.toFixed(2) + "%");
        card.style.setProperty("--my", st.my.toFixed(2) + "%");
        return !done;
      }
    };
    function aim(e) {
      if (!st.rect) st.rect = card.getBoundingClientRect();
      var x = clamp((e.clientX - st.rect.left) / st.rect.width, 0, 1), y = clamp((e.clientY - st.rect.top) / st.rect.height, 0, 1);
      st.tmx = x * 100; st.tmy = y * 100;
      st.trx = (0.5 - y) * 5; st.try = (x - 0.5) * 6;
    }
    card.addEventListener("pointerenter", function (e) {
      st.rect = card.getBoundingClientRect();
      aim(e);
      st.mx = st.tmx; st.my = st.tmy;
      card.classList.add("is-lit");
      wake(actor);
    });
    card.addEventListener("pointermove", function (e) { aim(e); wake(actor); });
    card.addEventListener("pointerleave", function () {
      st.rect = null;
      st.trx = 0; st.try = 0;
      card.classList.remove("is-lit");
      wake(actor);
    });
  });

  if (motion && finePointer) {
    var mags = [].slice.call(document.querySelectorAll(".hero .cta .btn-primary, .final .cta .btn-primary")).map(function (btn) {
      return { el: btn, x: 0, y: 0, vx: 0, vy: 0, tx: 0, ty: 0, key: "" };
    });
    var magActor = {
      tick: function (dt) {
        var busy = false, k = 240, c = 2 * Math.sqrt(k) * 0.68, n = Math.ceil(dt / 0.008), h = dt / n;
        mags.forEach(function (m) {
          for (var s = 0; s < n; s++) {
            m.vx += (k * (m.tx - m.x) - c * m.vx) * h; m.x += m.vx * h;
            m.vy += (k * (m.ty - m.y) - c * m.vy) * h; m.y += m.vy * h;
          }
          if (Math.abs(m.tx - m.x) < 0.02 && Math.abs(m.ty - m.y) < 0.02 && Math.abs(m.vx) < 0.05 && Math.abs(m.vy) < 0.05) { m.x = m.tx; m.y = m.ty; m.vx = m.vy = 0; }
          else busy = true;
          var css = m.x || m.y ? m.x.toFixed(2) + "px " + m.y.toFixed(2) + "px" : "";
          if (css !== m.key) { m.key = css; m.el.style.translate = css; }
        });
        return busy;
      }
    };
    var magPt = null, magRaf = 0;
    var magCheck = function () {
      magRaf = 0;
      if (!magPt) return;
      var moved = false;
      mags.forEach(function (m) {
        var r = m.el.getBoundingClientRect();
        if (r.bottom < -60 || r.top > vh + 60) return;
        var cx = r.left + r.width / 2 - m.x, cy = r.top + r.height / 2 - m.y;
        var dx = magPt.x - cx, dy = magPt.y - cy, pad = 34;
        var inside = Math.abs(dx) < r.width / 2 + pad && Math.abs(dy) < r.height / 2 + pad;
        var tx = inside ? clamp(dx * 0.16, -6, 6) : 0, ty = inside ? clamp(dy * 0.3, -6, 6) : 0;
        if (tx !== m.tx || ty !== m.ty) { m.tx = tx; m.ty = ty; moved = true; }
      });
      if (moved) wake(magActor);
    };
    document.addEventListener("pointermove", function (e) {
      if (e.pointerType && e.pointerType !== "mouse") return;
      magPt = { x: e.clientX, y: e.clientY };
      if (!magRaf) magRaf = requestAnimationFrame(magCheck);
    }, { passive: true });
    document.addEventListener("pointerleave", function () { magPt = { x: -1e4, y: -1e4 }; magCheck(); });
  }

  var navList = document.getElementById("nav-links");
  if (navList) {
    var spy = [].slice.call(navList.querySelectorAll('a[href^="#"]')).map(function (a) {
      return { a: a, el: document.getElementById(a.getAttribute("href").slice(1)), top: 0, bottom: 0 };
    }).filter(function (s) { return s.el && s.el.tagName === "SECTION"; });
    var pill = document.createElement("li");
    pill.className = "nav-pill";
    pill.setAttribute("aria-hidden", "true");
    pill.setAttribute("role", "presentation");
    navList.insertBefore(pill, navList.firstChild);
    var spyOn = -2, pillShown = false;
    var placePill = function (instant) {
      if (spyOn < 0) { pill.classList.remove("is-on"); pillShown = false; return; }
      var a = spy[spyOn].a;
      if (instant || !pillShown) pill.classList.add("no-anim");
      pill.style.setProperty("--px", a.offsetLeft + "px");
      pill.style.setProperty("--pw", a.offsetWidth + "px");
      if (instant || !pillShown) { void pill.offsetWidth; pill.classList.remove("no-anim"); }
      pill.classList.add("is-on");
      pillShown = true;
    };
    scenes.push({
      on: true,
      measure: function () {
        spy.forEach(function (s) { s.top = docTop(s.el); s.bottom = s.top + s.el.offsetHeight; });
        if (spyOn >= 0) placePill(true);
      },
      update: function (s, y) {
        var line = y + vh * 0.38, hit = -1;
        for (var i = 0; i < spy.length; i++) if (line >= spy[i].top && line < spy[i].bottom) hit = i;
        if (hit === spyOn) return;
        spyOn = hit;
        spy.forEach(function (s, i) { if (i === hit) s.a.setAttribute("aria-current", "location"); else s.a.removeAttribute("aria-current"); });
        placePill(false);
      }
    });
  }

  var RINGS = {
    mac: { w: 1600, h: 958, r: [[695, 72, 887, 98], [18, 80, 227, 245], [683, 292, 905, 228], [708, 545, 534, 255], [693, 163, 890, 36]] },
    windows: { w: 1586, h: 993, r: [[635, 50, 867, 95], [6, 122, 228, 292], [625, 265, 955, 215], [650, 545, 515, 222], [635, 143, 937, 32]] },
    linux: { w: 1590, h: 990, r: [[685, 62, 883, 98], [10, 85, 275, 219], [675, 295, 910, 225], [698, 560, 567, 160], [684, 158, 884, 36]] }
  };
  var STORY_DIR = { mac: "img/", windows: "img/windows/", linux: "img/linux/" };

  var story = document.querySelector("[data-story]");
  if (story) {
    var steps = [].slice.call(story.querySelectorAll(".story-step"));
    var links = [].slice.call(story.querySelectorAll(".step-link"));
    var layers = [].slice.call(story.querySelectorAll(".story-layer"));
    var chips = [].slice.call(story.querySelectorAll(".story-chip .chip-text span"));
    var count = story.querySelector("[data-story-count]");
    var railFill = story.querySelector(".rail-fill");
    var track = story.querySelector(".story-track");
    var stageEl = story.querySelector(".story-stage");
    var N = steps.length;
    var pinMQ = window.matchMedia("(min-width: 900px) and (min-height: 640px)");
    var pinned = false, trackTop = 0, dist = 1, active = -1, cams = [], cache = [], rollCol = null;
    steps.forEach(function (s, i) {
      s.style.setProperty("--row", i + 1);
      var p = s.querySelector("p");
      if (motion && p) wrapWords(p, "lw");
    });
    if (count) {
      var digits = "";
      for (var d = 1; d <= N; d++) digits += "<span>" + d + "</span>";
      count.innerHTML = '<span class="rl-d">0</span><span class="rl"><span class="rl-col">' + digits + "</span></span>";
      rollCol = count.querySelector(".rl-col");
    }

    var applyPlatform = function () {
      var key = root.getAttribute("data-platform") || "mac", R = RINGS[key] || RINGS.mac, dir = STORY_DIR[key] || "img/";
      cams = [];
      layers.forEach(function (layer, i) {
        var img = layer.querySelector("img"), src = dir + img.getAttribute("data-story-shot");
        if (img.getAttribute("src") !== src) { img.setAttribute("width", R.w); img.setAttribute("height", R.h); img.src = src; }
        var r = R.r[i], pad = 10, x = r[0] - pad, y = r[1] - pad, w = r[2] + pad * 2, h = r[3] + pad * 2, rr = 16;
        var svg = layer.querySelector("svg");
        svg.setAttribute("viewBox", "0 0 " + R.w + " " + R.h);
        var hole = "M" + (x + rr) + " " + y + "H" + (x + w - rr) + "A" + rr + " " + rr + " 0 0 1 " + (x + w) + " " + (y + rr) + "V" + (y + h - rr) + "A" + rr + " " + rr + " 0 0 1 " + (x + w - rr) + " " + (y + h) + "H" + (x + rr) + "A" + rr + " " + rr + " 0 0 1 " + x + " " + (y + h - rr) + "V" + (y + rr) + "A" + rr + " " + rr + " 0 0 1 " + (x + rr) + " " + y + "Z";
        svg.querySelector(".ring-dim").setAttribute("d", "M0 0H" + R.w + "V" + R.h + "H0Z" + hole);
        svg.querySelectorAll("rect").forEach(function (rect) {
          rect.setAttribute("x", x); rect.setAttribute("y", y); rect.setAttribute("width", w); rect.setAttribute("height", h); rect.setAttribute("rx", rr);
        });
        var cx = (r[0] + r[2] / 2) / R.w, cy = (r[1] + r[3] / 2) / R.h;
        var s = clamp(Math.min(0.8 / (r[2] / R.w), 0.74 / (r[3] / R.h)), 1, 1.55);
        cams.push({ s: s, tx: clamp(0.5 - cx * s, 1 - s, 0), ty: clamp(0.5 - cy * s, 1 - s, 0) });
      });
      cache = [];
      requestFrame();
    };

    var render = function (pos) {
      for (var i = 0; i < N; i++) {
        var d = pos - i, cam = cams[i] || { s: 1, tx: 0, ty: 0 };
        var op = (i === 0 ? 1 : smooth((d + 0.07) / 0.14)) * (d < 1.12 || i === N - 1 ? 1 : 0);
        var z = ease(clamp((d - 0.06) / 0.5, 0, 1));
        var ringOn = d >= 0.42 && op > 0.5;
        var s = 1 + (cam.s - 1) * z, tx = cam.tx * z * 100, ty = cam.ty * z * 100;
        var key = op.toFixed(3) + "|" + s.toFixed(4) + "|" + tx.toFixed(2) + "|" + ty.toFixed(2) + "|" + ringOn;
        if (cache[i] === key) continue;
        cache[i] = key;
        var layer = layers[i];
        layer.style.opacity = op.toFixed(3);
        layer.style.visibility = op > 0 ? "" : "hidden";
        layer.style.transform = "translate3d(" + tx.toFixed(2) + "%," + ty.toFixed(2) + "%,0) scale(" + s.toFixed(4) + ")";
        if (layer.__ring !== ringOn) { layer.__ring = ringOn; layer.classList.toggle("ring-on", ringOn); }
      }
      if (railFill) railFill.style.strokeDashoffset = (1 - clamp(pos / (N - 1), 0, 1)).toFixed(4);
      var a = clamp(Math.floor(pos + 0.02), 0, N - 1);
      if (a !== active) setActive(a);
    };

    var setActive = function (a) {
      active = a;
      var p = steps[a].querySelector("p");
      if (p && motion) numberLines(p);
      steps.forEach(function (s, i) {
        s.classList.toggle("is-active", i === a);
        s.classList.toggle("is-done", i < a);
      });
      links.forEach(function (l, i) { if (i === a) l.setAttribute("aria-current", "step"); else l.removeAttribute("aria-current"); });
      chips.forEach(function (c, i) { c.classList.toggle("is-on", i === a); });
      if (rollCol) rollCol.style.transform = "translate3d(0," + (-a * 1.25) + "em,0)";
    };

    var storyScene = {
      measure: function () {
        if (!pinned) return;
        trackTop = docTop(track);
        dist = Math.max(1, track.offsetHeight - stageEl.offsetHeight);
      },
      update: function (y) {
        if (!pinned) return;
        render(Math.min(clamp((y - trackTop) / dist, 0, 1) * N, N - 0.001));
      }
    };

    var setMode = function () {
      var want = motion && pinMQ.matches;
      if (want === pinned) return;
      pinned = want;
      story.classList.toggle("is-pinned", pinned);
      story.style.setProperty("--story-steps", N);
      if (pinned) {
        cache = []; active = -1;
        if (!cams.length) applyPlatform();
      } else {
        steps.forEach(function (s) { s.classList.remove("is-active", "is-done"); });
        links.forEach(function (l) { l.removeAttribute("aria-current"); });
      }
      invalidate();
    };

    links.forEach(function (link, i) {
      link.addEventListener("click", function (e) {
        if (!pinned) return;
        e.preventDefault();
        glideTo(trackTop + ((i + 0.68) / N) * dist);
      });
    });

    if (motion) {
      applyPlatform();
      document.addEventListener("platformchange", applyPlatform);
      watch(storyScene, story, "100px 0px 100px 0px");
      setMode();
      if (pinMQ.addEventListener) pinMQ.addEventListener("change", setMode); else if (pinMQ.addListener) pinMQ.addListener(setMode);
    }
  }

  var finalHost = document.querySelector("[data-final-logo]");
  if (motion && finalHost && hasIO) {
    var finalLogo = new Logo(finalHost, { bg: true });
    finalLogo.showBg(false);
    finalLogo.set(0);
    var fio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        fio.disconnect();
        finalLogo.draw(1700);
        setTimeout(function () { finalLogo.showBg(true); }, 1450);
      });
    }, { threshold: 0.6 });
    fio.observe(finalHost);
  }

  var main = document.getElementById("main");
  var line = document.querySelector("[data-stack-line]");
  if (line && main) {
    var lineOn = false, mainTop = 0, samples = [], total = 0, nodeYs = [], lit = [], lastLen = -1, rebuildTimer = 0, sig = "";
    var fill = line.querySelector(".sl-fill"), trackPath = line.querySelector(".sl-track"), nodesG = line.querySelector(".sl-nodes"), grad = line.querySelector("linearGradient");
    var targets = [].slice.call(document.querySelectorAll("[data-stack-node]"));
    var COLORS = ["#A78BFA", "#38BDF8", "#FB7185", "#A78BFA", "#38BDF8", "#FB7185", "#A78BFA"];
    var rebuild = function () {
      rebuildTimer = 0;
      var wrap = main.querySelector(".wrap");
      if (!wrap) return;
      var contentLeft = wrap.getBoundingClientRect().left + parseFloat(getComputedStyle(wrap).paddingLeft);
      var x0 = contentLeft - 64;
      var ok = window.innerWidth >= 1320 && x0 >= 30;
      line.classList.toggle("is-on", ok);
      lineOn = ok;
      if (!ok) return;
      mainTop = docTop(main);
      var ys = targets.map(function (t) {
        var anchor = t.querySelector(".eyebrow") || t.querySelector("h2") || t;
        var sticky = t.hasAttribute("data-story");
        return Math.round((sticky ? docTop(t) + 120 : docTop(anchor) + anchor.offsetHeight / 2) - mainTop);
      });
      var H = main.offsetHeight;
      var key = Math.round(x0) + ":" + ys.join(",") + ":" + H;
      if (key === sig) return;
      sig = key;
      line.style.left = Math.round(x0 - 30) + "px";
      line.style.height = H + "px";
      line.setAttribute("viewBox", "0 0 72 " + H);
      line.setAttribute("height", H);
      grad.setAttribute("y2", H);
      var lane = function (i) { return i % 2 ? 46 : 26; };
      var d = "M" + lane(0) + " " + Math.max(0, ys[0] - 260);
      var px = lane(0);
      ys.forEach(function (y, i) {
        var x = lane(i);
        if (x !== px) d += " L" + px + " " + (y - 170) + " C" + px + " " + (y - 90) + " " + x + " " + (y - 90) + " " + x + " " + (y - 10);
        d += " L" + x + " " + y;
        px = x;
      });
      d += " L" + px + " " + (ys[ys.length - 1] + 140);
      fill.setAttribute("d", d);
      trackPath.setAttribute("d", d);
      total = fill.getTotalLength();
      fill.style.strokeDasharray = total + " " + total;
      samples = [];
      for (var k = 0; k <= 240; k++) {
        var L = (k / 240) * total;
        samples.push([L, fill.getPointAtLength(L).y]);
      }
      nodeYs = ys;
      nodesG.innerHTML = "";
      lit = [];
      ys.forEach(function (y, i) {
        var g = document.createElementNS(SVGNS, "g");
        g.setAttribute("style", "color:" + COLORS[i % COLORS.length]);
        g.innerHTML = '<circle class="sl-halo" cx="' + lane(i) + '" cy="' + y + '" r="14" fill="currentColor"/><circle class="sl-node" cx="' + lane(i) + '" cy="' + y + '" r="6" stroke="currentColor"/>';
        nodesG.appendChild(g);
        lit.push(false);
      });
      lastLen = -1;
      lineScene.update(sy);
    };
    var lenAt = function (y) {
      var lo = 0, hi = samples.length - 1;
      if (!samples.length) return 0;
      if (y <= samples[0][1]) return 0;
      if (y >= samples[hi][1]) return total;
      while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (samples[mid][1] < y) lo = mid; else hi = mid; }
      var a = samples[lo], b = samples[hi], f = b[1] === a[1] ? 0 : (y - a[1]) / (b[1] - a[1]);
      return a[0] + (b[0] - a[0]) * f;
    };
    var lineScene = {
      on: true,
      measure: function () {
        if (rebuildTimer) clearTimeout(rebuildTimer);
        rebuildTimer = setTimeout(function () { rebuild(); }, sig ? 140 : 0);
      },
      update: function (y) {
        if (!lineOn || !samples.length) return;
        var reach = motion ? y + vh * 0.62 - mainTop : 1e9;
        var len = lenAt(reach);
        if (Math.abs(len - lastLen) > 0.5) { lastLen = len; fill.style.strokeDashoffset = (total - len).toFixed(1); }
        var gs = nodesG.children;
        for (var i = 0; i < nodeYs.length; i++) {
          var on = nodeYs[i] <= reach;
          if (on !== lit[i]) { lit[i] = on; gs[i].classList.toggle("is-lit", on); }
        }
      }
    };
    scenes.push(lineScene);
  }

  var yard = document.querySelector("[data-yard]");
  if (yard) voyage();

  function voyage() {
    var ysvg = yard.querySelector(".yard-svg"), yInner = yard.querySelector(".yard-inner");
    var stacksG = ysvg.querySelector(".yd-stacks"), trolley = ysvg.querySelector(".yd-trolley"), cable = ysvg.querySelector(".yd-cable"), hookG = ysvg.querySelector(".yd-hookg"), lift = ysvg.querySelector(".yd-lift");
    var tip = yard.querySelector(".yard-tip"), toast = yard.querySelector(".yard-toast");
    var STATE = { open: ["#5dbe8a", "Open"], merged: ["#9d8cf0", "Merged"], draft: ["#8b97ab", "Draft"], closed: ["#ee6f5f", "Closed"] };
    var COLS = [50, 90, 130, 170, 210], CW = 34, DECK = 104, BERTH = 395, TR_REST = 282, HOOK_REST = 34, CARRY = 26, MAXH = 3, HZ = 30, SEA_H = 170;
    var STACK = [
      [[594, "Detect quoted file paths with spaces as implicit links", "merged"], [708, "Notify hosts of in-place row shifts and count buffer resets", "merged"]],
      [[710, "macOS: re-snap the cell grid when the backing scale changes", "merged"], [731, "iOS Metal: dirty only the updated rows, not the whole grid", "open"], [744, "Let the host draw links in a color of its own", "draft"]],
      [[736, "Expose copied active-buffer input state for terminal hosts", "closed"]],
      [[482, "Fix flaky SearchBar test", "merged"], [753, "Content snapshots: buffer selection and ranged regions", "open"]],
      [[735, "Fix wrapped search navigation and selection summaries", "open"]]
    ];
    var QUEUE = [[760, "Cancel stale searches"], [763, "Fix flaky SearchBar test on Linux"], [766, "Keep selection summaries after output"], [769, "Dirty only the updated rows on Windows"]];
    var cols = [[], [], [], [], []];

    function setBox(g, n, title, state) {
      g.__pr = { n: n, t: title, s: state };
      g.style.setProperty("--c", STATE[state][0]);
      g.querySelector("text").textContent = "#" + n;
    }
    function boxMarkup() {
      return '<rect class="ct-body" width="34" height="15" rx="1.6"/><path class="ct-rib" d="M4 3.5v8M30 3.5v8"/><rect class="ct-flash" x="-1" y="-1" width="36" height="17" rx="2.4"/><text x="17" y="10.4"></text>';
    }
    function addBox(ci, n, title, state) {
      var g = document.createElementNS(SVGNS, "g");
      g.setAttribute("class", "ct");
      g.innerHTML = boxMarkup();
      setBox(g, n, title, state);
      var k = cols[ci].length;
      g.setAttribute("transform", "translate(" + COLS[ci] + " " + (DECK - (k + 1) * 16 + 1) + ")");
      stacksG.appendChild(g);
      cols[ci].push(g);
      return g;
    }
    STACK.forEach(function (col, ci) { col.forEach(function (b) { addBox(ci, b[0], b[1], b[2]); }); });
    lift.innerHTML = boxMarkup();

    var tipFor = null;
    function showTip(g) {
      var pr = g.__pr, r = g.getBoundingClientRect(), b = yInner.getBoundingClientRect();
      tipFor = g;
      tip.querySelector(".tip-n").textContent = "#" + pr.n;
      tip.querySelector(".tip-t").textContent = pr.t;
      var s = tip.querySelector(".tip-s");
      s.textContent = STATE[pr.s][1];
      s.style.setProperty("--c", STATE[pr.s][0]);
      var x = r.left + r.width / 2 - b.left, w = tip.offsetWidth || 220;
      x = clamp(x, w / 2 + 4 - b.left, vw - b.left - w / 2 - 4);
      tip.style.left = x.toFixed(1) + "px";
      tip.style.top = (r.top - b.top).toFixed(1) + "px";
      tip.classList.add("is-on");
      stacksG.querySelectorAll(".is-hover").forEach(function (o) { o.classList.remove("is-hover"); });
      g.classList.add("is-hover");
    }
    function hideTip() {
      tipFor = null;
      tip.classList.remove("is-on");
      stacksG.querySelectorAll(".is-hover").forEach(function (o) { o.classList.remove("is-hover"); });
    }
    stacksG.addEventListener("pointerover", function (e) { var g = e.target.closest(".ct"); if (g && g !== tipFor) showTip(g); });
    stacksG.addEventListener("pointerout", function (e) { var g = e.target.closest(".ct"); if (g && !(e.relatedTarget && g.contains(e.relatedTarget))) hideTip(); });

    var sea = document.createElement("div");
    sea.className = "sea";
    sea.setAttribute("aria-hidden", "true");
    var seed = 7, rnd = function () { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
    var stars = "";
    for (var si = 0; si < 18; si++) {
      var sx = rnd() * 100;
      if (sx > 30 && sx < 70) sx = sx < 50 ? sx - 26 : sx + 26;
      stars += '<i class="st" style="--x:' + clamp(sx, 1, 99).toFixed(2) + "%;--y:" + (10 + rnd() * 92).toFixed(1) + "px;--z:" + (1.1 + rnd() * 1.4).toFixed(2) + "px;--d:" + (2.4 + rnd() * 4.6).toFixed(2) + "s;--l:-" + (rnd() * 7).toFixed(2) + 's"></i>';
    }
    stars += '<i class="st big" style="--x:88.5%;--y:34px;--z:3px;--d:5.2s;--l:-2s"></i>';
    var gull = '<svg viewBox="0 0 16 7"><path d="M1 6 Q4.5 1.2 8 5 Q11.5 1.2 15 6"/></svg>';
    sea.innerHTML = '<div class="sea-stars">' + stars + "</div>" +
      '<div class="sea-clouds"><i class="cl c1"></i><i class="cl c2"></i><i class="cl c3"></i></div>' +
      '<div class="sea-gulls"><i class="gl g1">' + gull + '</i><i class="gl g2">' + gull + "</i></div>" +
      '<div class="sea-water"></div><div class="sea-line"></div>' +
      '<div class="sea-floats"><i class="fl" style="--c:#5dbe8a;--t:118s;--l:-38s"><i></i></i><i class="fl" style="--c:#9d8cf0;--t:156s;--l:-121s"><i></i></i><i class="fl" style="--c:#ee6f5f;--t:197s;--l:-12s"><i></i></i></div>' +
      '<div class="sea-fx"></div>';
    document.body.appendChild(sea);
    var fx = sea.querySelector(".sea-fx");

    var boat = document.createElement("button");
    boat.type = "button";
    boat.className = "boat";
    boat.setAttribute("aria-label", "PullYard boat: sail to the yard");
    boat.innerHTML = '<span class="boat-tilt"><span class="boat-hop"><span class="boat-bob"><span class="boat-flip">' +
      '<svg viewBox="440 340 460 420" aria-hidden="true" focusable="false"><defs><linearGradient id="bt-h" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FB7185"/><stop offset="1" stop-color="#D61F4E"/></linearGradient></defs>' +
      '<g class="bt-cargo"><rect class="bt-box" x="486" y="500" width="94" height="66" rx="7"/><path class="bt-rib" d="M504 514v38M562 514v38"/></g>' +
      '<rect x="702" y="392" width="40" height="86" rx="8" fill="#E2E8F0"/><rect x="702" y="392" width="40" height="20" rx="6" fill="#FB7185"/>' +
      '<rect x="584" y="462" width="176" height="104" rx="16" fill="#F8FAFC"/><rect x="584" y="540" width="176" height="26" fill="#E2E8F0"/>' +
      '<rect x="610" y="488" width="38" height="34" rx="8" fill="#1E293B"/><rect x="664" y="488" width="38" height="34" rx="8" fill="#1E293B"/>' +
      '<path d="M470 566 L866 566 L800 728 L540 728 Z" fill="url(#bt-h)"/><path d="M470 566 L866 566 L857 590 L480 590 Z" fill="#FECDD3"/>' +
      '<circle cx="770" cy="642" r="15" fill="#FFE4E6" opacity=".9"/></svg></span></span></span></span>';
    var tilt = boat.querySelector(".boat-tilt"), hop = boat.querySelector(".boat-hop"), flip = boat.querySelector(".boat-flip"), cargoEl = boat.querySelector(".bt-cargo"), boatSvg = boat.querySelector("svg");

    var bubble = document.createElement("div");
    bubble.className = "ahoy";
    bubble.setAttribute("role", "status");

    var B = { x: 0, v: 0, face: 1, W: 58, H: 53, berth: 0, start: 40, maxY: 1, svgScale: 1, sc: 1, lastX: 0, dist: 0, cargo: null, qi: 0, merging: false, lastBig: 0, sv: 0, lastRaw: window.scrollY, init: false, key: "", tkey: "" };
    var yardOn = !hasIO;

    if (motion) {
      document.body.appendChild(boat);
    } else {
      boat.classList.add("is-static");
      yInner.appendChild(boat);
    }
    document.body.appendChild(bubble);

    function loadCargo(animate) {
      var q = QUEUE[B.qi++ % QUEUE.length];
      B.cargo = { n: q[0], t: q[1] };
      boat.style.setProperty("--cargo", STATE.open[0]);
      boat.classList.remove("is-unloaded");
      if (animate && cargoEl.animate) cargoEl.animate([{ transform: "translateY(-60px)", opacity: 0 }, { transform: "translateY(6px)", opacity: 1, offset: 0.7 }, { transform: "none", opacity: 1 }], { duration: 620, easing: "cubic-bezier(.3,.7,.3,1)" });
    }
    loadCargo(false);

    function targetX(y) { return B.start + (B.berth - B.start) * clamp(y / B.maxY, 0, 1); }
    function chimney() {
      var relx = B.face > 0 ? 0.613 : 0.387;
      return { x: B.x + (relx - 0.5) * B.W * B.sc, y: SEA_H - HZ - 0.733 * B.H * B.sc };
    }
    function tr(x, y, s) { return "translate3d(" + x.toFixed(1) + "px," + y.toFixed(1) + "px,0) scale(" + s + ")"; }
    function pool(cls, n, html) {
      var list = [];
      for (var i = 0; i < n; i++) {
        var e = document.createElement("i");
        e.className = cls;
        if (html) e.innerHTML = html;
        fx.appendChild(e);
        list.push(e);
      }
      var k = 0;
      return function () { k = (k + 1) % n; return list[k]; };
    }
    var nextPuff = pool("pf", 12), nextRing = pool("rg", 4), nextWake = pool("wk", 14, '<svg viewBox="0 0 18 6"><path d="M1 4.6 C4 1.4 7 1.4 9 3.4 S14 5.6 17 2.4"/></svg>');
    function puff(big, delay) {
      if (!motion) return;
      var c = chimney(), e = nextPuff(), dir = -B.face;
      var s0 = big ? 0.7 : 0.45, s1 = big ? 2.5 : 1.6, dx = dir * (big ? 30 : 16) + (Math.random() * 8 - 4), dy = big ? -54 : -36;
      e.animate([
        { transform: tr(c.x, c.y, s0), opacity: big ? 0.8 : 0.6 },
        { transform: tr(c.x + dx * 0.45, c.y + dy * 0.55, (s0 + s1) / 2), opacity: big ? 0.5 : 0.38, offset: 0.45 },
        { transform: tr(c.x + dx, c.y + dy, s1), opacity: 0 }
      ], { duration: big ? 2100 : 1800, delay: delay || 0, easing: "cubic-bezier(.2,.6,.3,1)", fill: "backwards" });
    }
    function bigPuff() { puff(true); puff(true, 150); puff(false, 320); }
    function wakeAt() {
      var e = nextWake(), dir = -B.face, sx = B.x + dir * 0.31 * B.W * B.sc, y = SEA_H - HZ + 1;
      e.animate([
        { transform: "translate3d(" + sx.toFixed(1) + "px," + y + "px,0) scale(" + (0.55 * dir) + ",.6)", opacity: 0.7 },
        { transform: "translate3d(" + (sx + dir * 12).toFixed(1) + "px," + (y + 3) + "px,0) scale(" + (1.5 * dir) + ",1)", opacity: 0 }
      ], { duration: 1300, easing: "cubic-bezier(.2,.7,.3,1)" });
    }
    function setFace(f) {
      B.face = f;
      flip.classList.toggle("is-back", f < 0);
    }

    var boatActor = {
      tick: function (dt, now, y) {
        var p = clamp(y / B.maxY, 0, 1), tx = targetX(y);
        var n = Math.ceil(dt / 0.008), h = dt / n, k = 26, c = 2 * Math.sqrt(k) * 0.95;
        for (var s = 0; s < n; s++) { B.v += (k * (tx - B.x) - c * B.v) * h; B.x += B.v * h; }
        var sv = (y - B.lastRaw) / dt;
        B.lastRaw = y;
        B.sv += (sv - B.sv) * damp(9, dt);
        if (Math.abs(B.sv) > 2600 && now - B.lastBig > 1200) { B.lastBig = now; bigPuff(); }
        if (B.v < -45 && B.face > 0) setFace(-1); else if (B.v > 45 && B.face < 0) setFace(1);
        B.dist += Math.abs(B.x - B.lastX);
        B.lastX = B.x;
        if (B.dist > 15 && Math.abs(B.v) > 28) { B.dist = 0; wakeAt(); }
        var settled = Math.abs(tx - B.x) < 0.25 && Math.abs(B.v) < 3 && Math.abs(B.sv) < 4;
        if (settled) { B.x = tx; B.v = 0; B.sv = 0; }
        B.sc = 1 + 0.28 * smooth((p - 0.9) / 0.1);
        var rot = clamp(-B.v * 0.0065, -6, 6);
        var css = "translate3d(" + (B.x - B.W / 2).toFixed(2) + "px,0,0)";
        if (css !== B.key) { B.key = css; boat.style.transform = css; }
        var tcss = "rotate(" + rot.toFixed(2) + "deg) scale(" + B.sc.toFixed(4) + ")";
        if (tcss !== B.tkey) { B.tkey = tcss; tilt.style.transform = tcss; }
        if (p > 0.995 && settled && B.cargo && !B.merging && yardOn) startMerge();
        if (p < 0.85 && !B.cargo && !B.merging) loadCargo(true);
        return !settled;
      }
    };

    var voyageScene = {
      on: true,
      measure: function () {
        B.W = boat.offsetWidth || 58;
        B.H = boat.offsetHeight || 53;
        var pad = parseFloat(getComputedStyle(yInner).paddingLeft) || 0;
        B.svgScale = Math.min(1, (yInner.clientWidth - pad * 2) / 440);
        ysvg.style.transform = B.svgScale < 1 ? "scale(" + B.svgScale.toFixed(4) + ")" : "";
        var r = ysvg.getBoundingClientRect();
        B.berth = r.left + BERTH * B.svgScale;
        B.start = clamp(vw * 0.07, 34, 150);
        B.maxY = Math.max(1, document.documentElement.scrollHeight - vh);
        if (!motion) {
          var b = yInner.getBoundingClientRect();
          boat.style.left = (B.berth - b.left - B.W / 2).toFixed(1) + "px";
          tilt.style.transform = "scale(1.28)";
          B.sc = 1.28;
          return;
        }
        if (!B.init) { B.init = true; B.x = B.lastX = targetX(window.scrollY); }
        wake(boatActor);
      },
      update: function () {}
    };
    scenes.push(voyageScene);
    onScrollHooks.push(function () { if (motion) wake(boatActor); });

    if (hasIO) {
      new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          yardOn = e.isIntersecting;
          yard.classList.toggle("is-off", !yardOn);
          if (yardOn && motion) wake(boatActor);
        });
      }, { rootMargin: "0px 0px 40px 0px" }).observe(yard);
    }

    var M = null;
    function svgPoint(cx, cy) {
      var r = ysvg.getBoundingClientRect(), s = B.svgScale;
      return { x: (cx - r.left) / s, y: (cy - r.top) / s };
    }
    function startMerge() {
      var ci = -1, best = 99;
      cols.forEach(function (c, i) { if (c.length < MAXH && c.length < best) { best = c.length; ci = i; } });
      if (ci < 0) {
        ci = 0;
        cols[0].forEach(function (g) { g.classList.add("is-shipped"); setTimeout(function () { g.remove(); }, 420); });
        cols[0] = [];
      }
      var cr = cargoEl.getBoundingClientRect(), pt = svgPoint(cr.left + cr.width / 2, cr.top);
      B.merging = true;
      M = { t: 0, ci: ci, grabX: pt.x, grabY: pt.y - 3, s0: clamp(cr.width / B.svgScale / CW, 0.3, 1.2), grabbed: false, released: false, colX: COLS[ci] + CW / 2, landY: DECK - (cols[ci].length + 1) * 16 + 1 - 3, lastTx: TR_REST, sway: 0 };
      setBox(lift, B.cargo.n, B.cargo.t, "open");
      wake(mergeActor);
    }
    function seg(t, a, b) { return ease(clamp((t - a) / (b - a), 0, 1)); }
    var mergeActor = {
      tick: function (dt) {
        var m = M;
        if (!m) return false;
        m.t += dt * 1000;
        var t = m.t, tx, hy, sc = 1;
        if (t < 650) { tx = lerp(TR_REST, m.grabX, seg(t, 0, 650)); hy = HOOK_REST; }
        else if (t < 1100) { tx = m.grabX; hy = lerp(HOOK_REST, m.grabY, seg(t, 650, 1100)); }
        else if (t < 1750) { tx = m.grabX; hy = lerp(m.grabY, CARRY, seg(t, 1100, 1750)); sc = lerp(m.s0, 1, seg(t, 1100, 1750)); }
        else if (t < 2600) { tx = lerp(m.grabX, m.colX, seg(t, 1750, 2600)); hy = CARRY; }
        else if (t < 3050) { tx = m.colX; hy = lerp(CARRY, m.landY, seg(t, 2600, 3050)); }
        else if (t < 3450) { tx = m.colX; hy = lerp(m.landY, HOOK_REST, seg(t, 3050, 3450)); }
        else { tx = lerp(m.colX, TR_REST, seg(t, 3450, 4100)); hy = HOOK_REST; }
        if (!m.grabbed && t >= 1100) {
          m.grabbed = true;
          if (Math.abs(B.x - B.berth) > 8 || !B.cargo) {
            m.released = true;
            m.colX = m.grabX; m.landY = m.grabY;
            m.t = 3050;
          } else {
            boat.classList.add("is-unloaded");
            lift.style.display = "";
          }
        }
        if (m.grabbed && !m.released && t >= 3050) {
          m.released = true;
          lift.style.display = "none";
          var g = addBox(m.ci, B.cargo.n, B.cargo.t, "open");
          B.cargo = null;
          setTimeout(function () {
            setBox(g, g.__pr.n, g.__pr.t, "merged");
            g.classList.add("is-flash");
            showToast(m.colX, m.landY + 3);
            puff(false);
          }, 160);
        }
        var vel = (tx - m.lastTx) / Math.max(dt, 0.001);
        m.lastTx = tx;
        m.sway += (clamp(-vel * 0.05, -9, 9) - m.sway) * damp(6, dt);
        trolley.setAttribute("transform", "translate(" + tx.toFixed(2) + " 0)");
        cable.setAttribute("y2", hy.toFixed(2));
        hookG.setAttribute("transform", "translate(0 " + hy.toFixed(2) + ")");
        if (m.grabbed && !m.released) lift.setAttribute("transform", "translate(" + tx.toFixed(2) + " " + (hy + 3).toFixed(2) + ") rotate(" + m.sway.toFixed(2) + ") scale(" + sc.toFixed(3) + ") translate(-17 0)");
        if (m.t >= 4100) { M = null; B.merging = false; return false; }
        return true;
      }
    };
    var toastTimer = 0;
    function showToast(x, y) {
      var r = ysvg.getBoundingClientRect(), b = yInner.getBoundingClientRect(), s = B.svgScale;
      toast.style.left = (r.left - b.left + x * s).toFixed(1) + "px";
      toast.style.top = (r.top - b.top + y * s - 8).toFixed(1) + "px";
      toast.classList.add("is-on");
      clearTimeout(toastTimer);
      toastTimer = setTimeout(function () { toast.classList.remove("is-on"); }, 2600);
    }

    var honks = 0, bubbleTimer = 0;
    var ANCHOR = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><circle cx="12" cy="5" r="2.2"/><path d="M12 7.2V21M8 10.5h8M4.5 13.5c.7 4.3 3.7 7.5 7.5 7.5s6.8-3.2 7.5-7.5"/><path d="M3 15.5l1.5-2 2 1.4M21 15.5l-1.5-2-2 1.4"/></svg>';
    function ahoy() {
      bubble.innerHTML = ANCHOR + "<span><b>Ahoy, reviewer!</b><small>Five honks. The yard approves.</small></span>";
      var r = boatSvg.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top - 14;
      if (r.bottom < 0 || r.top > vh) { x = vw / 2; y = vh - 150; }
      bubble.style.left = clamp(x, 130, vw - 130).toFixed(1) + "px";
      bubble.style.top = clamp(y, 90, vh - 20).toFixed(1) + "px";
      bubble.classList.add("is-on");
      clearTimeout(bubbleTimer);
      bubbleTimer = setTimeout(function () { bubble.classList.remove("is-on"); }, 3800);
    }
    function horn() {
      honks++;
      if (motion) {
        hop.animate([
          { transform: "none" },
          { transform: "translateY(-9px) rotate(-5deg)", offset: 0.32 },
          { transform: "translateY(1px) rotate(1.5deg)", offset: 0.72 },
          { transform: "none" }
        ], { duration: 680, easing: "cubic-bezier(.3,.7,.4,1)" });
        var c = chimney();
        for (var i = 0; i < 3; i++) {
          nextRing().animate([
            { transform: tr(c.x, c.y - 4, 0.3), opacity: 0.85 },
            { transform: tr(c.x - B.face * 6, c.y - 16, 2.6), opacity: 0 }
          ], { duration: 950, delay: i * 170, easing: "cubic-bezier(.2,.7,.3,1)", fill: "backwards" });
        }
        puff(false, 60); puff(false, 260);
      }
      if (honks % 5 === 0) ahoy();
    }
    function inBoat(x, y) {
      var r = boatSvg.getBoundingClientRect(), pad = 6;
      return x >= r.left - pad && x <= r.right + pad && y >= r.top - pad && y <= r.bottom + pad;
    }
    function voyage() {
      var wasSailing = sailingAtDown || !!(glide && glide.voyage);
      sailingAtDown = false;
      if (wasSailing) { stopGlide(); return; }
      horn();
      var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      sailTo(window.scrollY >= max - 4 ? 0 : max);
    }
    boat.addEventListener("click", voyage);
    document.addEventListener("click", function (e) {
      if (e.defaultPrevented || boat.contains(e.target) || !e.detail) return;
      if (e.target.closest && e.target.closest(INTERACTIVE)) return;
      if (inBoat(e.clientX, e.clientY)) voyage();
    });
    document.addEventListener("keydown", function (e) {
      if (e.repeat || e.metaKey || e.ctrlKey || e.altKey || (e.key !== "h" && e.key !== "H")) return;
      var t = e.target;
      if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || (t.closest && t.closest("[role=application]")))) return;
      horn();
    });
    if (finePointer) {
      var hot = false, hp = null, hpRaf = 0;
      var checkHot = function () {
        hpRaf = 0;
        if (!hp) return;
        var on = inBoat(hp.x, hp.y) && !(hp.t && hp.t.closest && hp.t.closest(INTERACTIVE));
        if (on !== hot) { hot = on; boat.classList.toggle("is-hot", on); root.classList.toggle("boat-hot", on); }
      };
      document.addEventListener("pointermove", function (e) {
        hp = { x: e.clientX, y: e.clientY, t: e.target };
        if (!hpRaf) hpRaf = requestAnimationFrame(checkHot);
      }, { passive: true });
    }

    if (motion) {
      (function idlePuff() {
        setTimeout(function () {
          if (!document.hidden) puff(false);
          idlePuff();
        }, 3200 + Math.random() * 4200);
      })();
    }
  }

  invalidate();
})();
