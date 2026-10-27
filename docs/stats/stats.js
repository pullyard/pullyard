(() => {
  const REPO = "pullyard/pullyard";
  const API = "https://api.github.com";
  const KEYS = {
    token: "pullyard-stats-token",
    snaps: "pullyard-stats-snapshots",
    traffic: "pullyard-stats-traffic",
    theme: "pullyard-theme",
    umami: "pullyard-stats-umami"
  };
  const UMAMI_API = "https://api.umami.is/v1";
  const UMAMI_APP = "https://cloud.umami.is/analytics";
  const UMAMI_REGIONS = ["us", "eu"];
  const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  const regionNames = typeof Intl.DisplayNames === "function" ? new Intl.DisplayNames(["en"], { type: "region" }) : null;
  const DOWNLOAD_PLATFORMS = [
    { id: "macos", name: "macOS", color: "var(--c1)" },
    { id: "windows", name: "Windows", color: "var(--c2)" },
    { id: "linux", name: "Linux", color: "var(--c3)" }
  ];
  const ACTION_NAMES = { github: "GitHub repo", "releases-page": "Releases page", "copy-command": "Install command copied", "download-other": "Other file" };
  const PLATFORMS = [
    { id: "mac", name: "macOS", color: "var(--c1)" },
    { id: "win", name: "Windows", color: "var(--c2)" },
    { id: "linux", name: "Linux", color: "var(--c3)" }
  ];
  const STALE_MS = 60 * 60 * 1000;
  const DAY_MS = 86400000;

  const store = {
    get(area, key, fallback) {
      try {
        const raw = area.getItem(key);
        return raw == null ? fallback : JSON.parse(raw);
      } catch (e) {
        return fallback;
      }
    },
    set(area, key, value) {
      try { area.setItem(key, JSON.stringify(value)); } catch (e) {}
    },
    remove(key) {
      try { localStorage.removeItem(key); sessionStorage.removeItem(key); } catch (e) {}
    }
  };

  const themePref = () => {
    try { return localStorage.getItem(KEYS.theme) || "auto"; } catch (e) { return "auto"; }
  };
  const applyTheme = pref => {
    if (pref === "auto") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", pref);
  };
  applyTheme(themePref());

  const nf = new Intl.NumberFormat("en-US");
  const cf = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
  const fmt = n => (n >= 10000 ? cf.format(n) : nf.format(n));
  const pct = (a, b) => (b ? Math.round((a / b) * 100) + "%" : "0%");
  const dayKey = d => new Date(d).toISOString().slice(0, 10);
  const shortDate = d => new Date(d).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  const longDate = d => new Date(d).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const ago = t => {
    const s = Math.max(0, Math.round((Date.now() - t) / 1000));
    if (s < 45) return "just now";
    const m = Math.round(s / 60);
    if (m < 60) return m + " min ago";
    const h = Math.round(m / 60);
    if (h < 24) return h + " h ago";
    const d = Math.round(h / 24);
    return d === 1 ? "yesterday" : d + " days ago";
  };

  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    applyAttrs(el, attrs);
    append(el, kids);
    return el;
  }
  function s(tag, attrs, ...kids) {
    const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
    applyAttrs(el, attrs);
    append(el, kids);
    return el;
  }
  function applyAttrs(el, attrs) {
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === "class") el.setAttribute("class", v);
      else if (k === "style") for (const [p, val] of Object.entries(v)) el.style.setProperty(p, val);
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? "" : v);
    }
  }
  function append(el, kids) {
    for (const k of kids.flat(Infinity)) {
      if (k == null || k === false) continue;
      el.append(k.nodeType ? k : document.createTextNode(String(k)));
    }
  }

  function scale(max) {
    const target = Math.max(1, max);
    const raw = target / 4;
    const p = 10 ** Math.floor(Math.log10(raw));
    const f = raw / p;
    const step = Math.max(1, (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p);
    const top = Math.ceil(target / step) * step;
    const ticks = [];
    for (let v = 0; v <= top + 1e-9; v += step) ticks.push(v);
    return { top, ticks };
  }

  const tip = {
    el: null,
    show(px, py, title, rows, total) {
      const el = this.el;
      el.replaceChildren();
      append(el, [
        h("p", { class: "tip-title" }, title),
        rows.map(r => h("div", { class: "tip-row" },
          h("i", { class: "key-line", style: { background: r.color } }),
          h("b", null, r.value),
          h("span", null, r.label))),
        total ? h("div", { class: "tip-row total" }, h("i", { class: "key-line" }), h("b", null, total.value), h("span", null, total.label)) : null
      ]);
      el.hidden = false;
      const w = el.offsetWidth, ht = el.offsetHeight;
      let x = px + 14, y = py - ht - 10;
      if (x + w > window.innerWidth - 8) x = px - w - 14;
      if (x < 8) x = 8;
      if (y < 8) y = py + 14;
      el.style.left = x + "px";
      el.style.top = y + "px";
    },
    hide() { if (this.el) this.el.hidden = true; }
  };

  function lineChart(host, cfg) {
    const { labels, series, height = 240, area, ariaLabel, compact, connectGaps } = cfg;
    host.replaceChildren();
    const n = labels.length;
    if (!n) return;
    const W = Math.max(280, host.clientWidth);
    const H = height;
    const showEnd = !compact && series.length > 1 && series.length <= 4;
    const m = compact ? { t: 6, r: 6, b: 6, l: 6 } : { t: 14, r: showEnd ? 92 : 18, b: 28, l: 40 };
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const all = series.flatMap(x => x.values).filter(v => v != null);
    const { top, ticks } = scale(all.length ? Math.max(...all) : 1);
    const x = i => m.l + (n < 2 ? iw / 2 : (i * iw) / (n - 1));
    const y = v => m.t + ih - (v / top) * ih;
    const root = s("svg", { viewBox: `0 0 ${W} ${H}`, width: "100%", height: H, class: "chart" });

    if (!compact) {
      for (const t of ticks) {
        root.append(
          s("line", { x1: m.l, x2: W - m.r, y1: y(t), y2: y(t), class: t === 0 ? "baseline" : "grid" }),
          s("text", { x: m.l - 8, y: y(t) + 4, "text-anchor": "end", class: "tick" }, nf.format(t))
        );
      }
      const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(iw / 76))));
      for (let i = 0; i < n; i += every) {
        const anchor = n > 1 && i === 0 ? "start" : i >= n - every / 2 ? "end" : "middle";
        root.append(s("text", { x: x(i), y: H - 6, "text-anchor": anchor, class: "tick" }, labels[i].short));
      }
    }

    const segmentsOf = values => {
      const segs = [];
      let cur = null;
      values.forEach((v, i) => {
        if (v == null) { if (!connectGaps) cur = null; return; }
        if (!cur) { cur = []; segs.push(cur); }
        cur.push([x(i), y(v)]);
      });
      return segs;
    };

    const ends = [];
    for (const se of series) {
      const segs = segmentsOf(se.values);
      if (area && series.length === 1) {
        for (const seg of segs) {
          const d = "M" + seg.map(p => p[0].toFixed(1) + "," + p[1].toFixed(1)).join("L") +
            `L${seg[seg.length - 1][0].toFixed(1)},${(m.t + ih).toFixed(1)}L${seg[0][0].toFixed(1)},${(m.t + ih).toFixed(1)}Z`;
          root.append(s("path", { d, class: "area", style: { fill: se.color } }));
        }
      }
      for (const seg of segs) {
        if (seg.length === 1) {
          root.append(s("circle", { cx: seg[0][0], cy: seg[0][1], r: 3, style: { fill: se.color } }));
          continue;
        }
        root.append(s("path", { d: "M" + seg.map(p => p[0].toFixed(1) + "," + p[1].toFixed(1)).join("L"), class: "line", style: { stroke: se.color } }));
      }
      let last = -1;
      se.values.forEach((v, i) => { if (v != null) last = i; });
      if (last >= 0) {
        root.append(s("circle", { cx: x(last), cy: y(se.values[last]), r: compact ? 3.5 : 4, class: "dot", style: { fill: se.color } }));
        ends.push({ y: y(se.values[last]), x: x(last), text: nf.format(se.values[last]) + " " + se.name });
      }
    }

    if (showEnd) {
      const sorted = [...ends].sort((a, b) => a.y - b.y);
      const clear = sorted.every((e, i) => i === 0 || e.y - sorted[i - 1].y >= 15);
      if (clear) for (const e of ends) root.append(s("text", { x: e.x + 10, y: e.y + 4, class: "endlabel" }, e.text));
    }

    if (compact) { host.append(root); return; }

    const cross = s("g", { visibility: "hidden" });
    const vline = s("line", { y1: m.t, y2: m.t + ih, class: "crossline" });
    const dots = series.map(se => s("circle", { r: 4, class: "dot", style: { fill: se.color } }));
    cross.append(vline, ...dots);
    root.append(cross);
    const hit = s("rect", { x: m.l - 12, y: 0, width: iw + 24, height: m.t + ih, fill: "transparent", class: "hit", tabindex: 0, role: "img", "aria-label": ariaLabel });
    root.append(hit);

    let cur = n - 1;
    const show = i => {
      cur = i;
      cross.setAttribute("visibility", "visible");
      vline.setAttribute("x1", x(i));
      vline.setAttribute("x2", x(i));
      series.forEach((se, k) => {
        const v = se.values[i];
        dots[k].setAttribute("visibility", v == null ? "hidden" : "visible");
        if (v != null) { dots[k].setAttribute("cx", x(i)); dots[k].setAttribute("cy", y(v)); }
      });
      const r = root.getBoundingClientRect();
      const k = r.width / W;
      const peak = Math.min(...series.map(se => (se.values[i] == null ? m.t + ih : y(se.values[i]))));
      tip.show(r.left + x(i) * k, r.top + peak * k, labels[i].long,
        series.map(se => ({ color: se.color, label: se.name, value: se.values[i] == null ? "–" : nf.format(se.values[i]) })));
    };
    const hide = () => { cross.setAttribute("visibility", "hidden"); tip.hide(); };
    hit.addEventListener("pointermove", e => {
      const r = root.getBoundingClientRect();
      const px = ((e.clientX - r.left) * W) / r.width;
      show(Math.min(n - 1, Math.max(0, n < 2 ? 0 : Math.round(((px - m.l) / iw) * (n - 1)))));
    });
    hit.addEventListener("pointerleave", hide);
    hit.addEventListener("focus", () => show(cur));
    hit.addEventListener("blur", hide);
    hit.addEventListener("keydown", e => {
      const next = { ArrowLeft: cur - 1, ArrowRight: cur + 1, Home: 0, End: n - 1 }[e.key];
      if (next == null) return;
      e.preventDefault();
      show(Math.min(n - 1, Math.max(0, next)));
    });
    host.append(root);
  }

  function roundedTop(x, y, w, hgt, r) {
    const rr = Math.min(r, hgt, w / 2);
    return `M${x},${y + hgt}V${y + rr}Q${x},${y} ${x + rr},${y}H${x + w - rr}Q${x + w},${y} ${x + w},${y + rr}V${y + hgt}Z`;
  }

  function stackedColumns(host, cfg) {
    const { cats, series, height = 260, ariaLabel } = cfg;
    host.replaceChildren();
    const n = cats.length;
    if (!n) return;
    host.append(legend(series, "rect"));
    const W = Math.max(280, host.clientWidth);
    const H = height;
    const m = { t: 20, r: 8, b: 28, l: 40 };
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const totals = cats.map((_, i) => series.reduce((a, se) => a + se.values[i], 0));
    const { top, ticks } = scale(Math.max(...totals));
    const y = v => m.t + ih - (v / top) * ih;
    const band = iw / n;
    const bw = Math.min(24, band * 0.62);
    const root = s("svg", { viewBox: `0 0 ${W} ${H}`, width: "100%", height: H, class: "chart", role: "group", "aria-label": ariaLabel });

    for (const t of ticks) {
      root.append(
        s("line", { x1: m.l, x2: W - m.r, y1: y(t), y2: y(t), class: t === 0 ? "baseline" : "grid" }),
        s("text", { x: m.l - 8, y: y(t) + 4, "text-anchor": "end", class: "tick" }, nf.format(t))
      );
    }
    const every = Math.max(1, Math.ceil(n / Math.max(1, Math.floor(iw / 52))));
    const showVals = band >= 30;

    const cols = cats.map((cat, i) => {
      const cx = m.l + band * (i + 0.5);
      const g = s("g", { class: "col" });
      let cum = 0;
      const drawn = series.map((se, k) => ({ se, k, v: se.values[i] })).filter(d => d.v > 0);
      drawn.forEach((d, j) => {
        const yTop = y(cum + d.v);
        let yBot = y(cum);
        if (j > 0) yBot -= 2;
        const hgt = Math.max(0, yBot - yTop);
        cum += d.v;
        if (hgt <= 0) return;
        const isTop = j === drawn.length - 1;
        g.append(isTop
          ? s("path", { d: roundedTop(cx - bw / 2, yTop, bw, hgt, 4), style: { fill: d.se.color } })
          : s("rect", { x: cx - bw / 2, y: yTop, width: bw, height: hgt, style: { fill: d.se.color } }));
      });
      if (showVals && totals[i] > 0) g.append(s("text", { x: cx, y: y(totals[i]) - 6, "text-anchor": "middle", class: "val" }, nf.format(totals[i])));
      root.append(g);
      if (i % every === 0) root.append(s("text", { x: cx, y: H - 8, "text-anchor": "middle", class: "tick" }, cat.short));
      return { g, cx };
    });

    const show = (i, target) => {
      root.classList.add("hovering");
      cols.forEach((c, k) => c.g.classList.toggle("on", k === i));
      const r = target.getBoundingClientRect();
      const k = root.getBoundingClientRect().width / W;
      tip.show(r.left + r.width / 2, root.getBoundingClientRect().top + y(totals[i]) * k, cats[i].long,
        series.map(se => ({ color: se.color, label: se.name, value: nf.format(se.values[i]) })),
        { label: cats[i].totalLabel || "Total", value: nf.format(totals[i]) });
    };
    const hide = () => { root.classList.remove("hovering"); cols.forEach(c => c.g.classList.remove("on")); tip.hide(); };

    cols.forEach((c, i) => {
      const hit = s("rect", {
        x: m.l + band * i, y: m.t, width: band, height: ih, fill: "transparent", class: "col-hit", tabindex: 0,
        role: "img", "aria-label": `${cats[i].long}: ${series.map(se => se.name + " " + se.values[i]).join(", ")}, total ${totals[i]}`
      });
      hit.addEventListener("pointerenter", () => show(i, hit));
      hit.addEventListener("pointerleave", hide);
      hit.addEventListener("focus", () => show(i, hit));
      hit.addEventListener("blur", hide);
      root.append(hit);
    });
    host.append(root);
  }

  function legend(series, kind) {
    return h("ul", { class: "legend" }, series.map(se =>
      h("li", null, h("i", { class: kind === "line" ? "key-line" : "key-rect", style: { background: se.color } }), se.name)));
  }

  function hbars(host, rows, color) {
    host.replaceChildren();
    if (!rows.length) return host.append(h("div", { class: "empty" }, "No data yet"));
    const max = Math.max(...rows.map(r => r.value), 1);
    host.append(h("ul", { class: "hbars" }, rows.map(r =>
      h("li", { class: "hrow" },
        h("span", { class: "hlabel" }, r.color ? h("i", { class: "key-rect", style: { background: r.color } }) : null, h("span", { title: r.label }, r.label)),
        h("span", { class: "htrack" }, h("span", { class: "hfill", style: { width: (r.value / max) * 100 + "%", background: r.color || color } })),
        h("span", { class: "hval" }, nf.format(r.value), r.sub ? h("small", null, r.sub) : null)))));
  }

  function table(host, cols, rows) {
    host.replaceChildren(h("table", null,
      h("thead", null, h("tr", null, cols.map(c => h("th", { class: c.num ? "num" : null, scope: "col" }, c.label)))),
      h("tbody", null, rows.map(r => h("tr", null, cols.map(c => {
        const v = r[c.key];
        return h("td", { class: [c.num ? "num" : "", c.cls || ""].join(" ").trim() || null }, v && v.nodeType ? v : c.num && typeof v === "number" ? nf.format(v) : v == null ? "–" : v);
      }))))));
  }

  function empty(host, text) {
    host.replaceChildren(h("div", { class: "empty" }, text));
  }

  function classify(name) {
    const n = name.toLowerCase();
    const sig = n.endsWith(".sig");
    const base = sig ? n.slice(0, -4) : n;
    let platform = null;
    if (base.endsWith(".dmg")) platform = "mac";
    else if (/windows|\.exe$|\.msi$/.test(base)) platform = "win";
    else if (/linux|\.deb$|\.rpm$|\.flatpak$|\.appimage$/.test(base)) platform = "linux";
    if (!platform) return null;
    const arch = /arm64|aarch64/.test(base) ? "arm64" : /x64|x86_64|amd64/.test(base) ? "x64" : platform === "mac" ? "Universal" : "";
    const format =
      base.endsWith(".dmg") ? "DMG" :
      base.endsWith(".exe") ? "Installer" :
      base.endsWith(".msi") ? "MSI" :
      base.endsWith(".zip") ? "Portable" :
      base.endsWith(".tar.gz") ? "tar.gz" :
      base.endsWith(".deb") ? "deb" :
      base.endsWith(".rpm") ? "rpm" :
      base.endsWith(".flatpak") ? "Flatpak" :
      base.endsWith(".appimage") ? "AppImage" : "Other";
    return { platform, arch, format, sig };
  }

  function aggregate(releases) {
    const rows = [];
    const formats = new Map();
    for (const r of releases) {
      if (r.draft) continue;
      const row = { tag: r.tag_name.replace(/^v/, ""), date: r.published_at || r.created_at, url: r.html_url, pre: r.prerelease, dl: { mac: 0, win: 0, linux: 0 }, up: { mac: 0, win: 0, linux: 0 } };
      for (const a of r.assets || []) {
        const c = classify(a.name);
        if (!c) continue;
        const key = [c.platform, c.format, c.arch].join("|");
        const f = formats.get(key) || { platform: c.platform, format: c.format, arch: c.arch, downloads: 0, updates: 0, files: new Set() };
        if (c.sig) { row.up[c.platform] += a.download_count; f.updates += a.download_count; }
        else { row.dl[c.platform] += a.download_count; f.downloads += a.download_count; f.files.add(a.name); }
        formats.set(key, f);
      }
      rows.push(row);
    }
    rows.sort((a, b) => new Date(a.date) - new Date(b.date));
    const sum = (field, id) => rows.reduce((a, r) => a + r[field][id], 0);
    const dl = Object.fromEntries(PLATFORMS.map(p => [p.id, sum("dl", p.id)]));
    const up = Object.fromEntries(PLATFORMS.map(p => [p.id, sum("up", p.id)]));
    return { rows, formats: [...formats.values()], dl, up };
  }

  const net = (dl, up, id) => Math.max(0, dl[id] - up[id]);
  const countFor = (dl, up, id, mode) => (mode === "net" ? net(dl, up, id) : dl[id]);
  const totalFor = (dl, up, mode) => PLATFORMS.reduce((a, p) => a + countFor(dl, up, p.id, mode), 0);

  function recordSnapshot(agg) {
    const snaps = store.get(localStorage, KEYS.snaps, []);
    const entry = { d: dayKey(Date.now()), dl: agg.dl, up: agg.up };
    if (snaps.length && snaps[snaps.length - 1].d === entry.d) snaps[snaps.length - 1] = entry;
    else snaps.push(entry);
    store.set(localStorage, KEYS.snaps, snaps.slice(-730));
    return snaps;
  }

  function mergeTraffic(kind, list) {
    const all = store.get(localStorage, KEYS.traffic, { views: {}, clones: {} });
    all[kind] = all[kind] || {};
    for (const v of list) all[kind][dayKey(v.timestamp)] = { c: v.count, u: v.uniques };
    store.set(localStorage, KEYS.traffic, all);
    return all;
  }

  function dailyRange(fromKey, toKey) {
    const out = [];
    for (let t = Date.parse(fromKey + "T00:00:00Z"); t <= Date.parse(toKey + "T00:00:00Z"); t += DAY_MS) out.push(dayKey(t));
    return out;
  }

  const state = {
    token: "",
    data: null,
    fetchedAt: 0,
    dlMode: "all",
    range: 14,
    kind: "views",
    rate: null,
    loading: false,
    tab: "overview",
    ws: { range: 30, data: null, loading: false }
  };

  function readToken() {
    try { return localStorage.getItem(KEYS.token) || sessionStorage.getItem(KEYS.token) || ""; } catch (e) { return ""; }
  }

  async function gh(path, accept) {
    const headers = { Accept: accept || "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
    if (state.token) headers.Authorization = "Bearer " + state.token;
    const res = await fetch(path.startsWith("http") ? path : API + path, { headers, cache: "no-store", referrerPolicy: "no-referrer" });
    const remaining = res.headers.get("x-ratelimit-remaining");
    if (remaining != null) state.rate = { remaining: +remaining, limit: +res.headers.get("x-ratelimit-limit"), reset: +res.headers.get("x-ratelimit-reset") * 1000 };
    if (!res.ok) {
      const err = new Error(res.status === 401 ? "The token was rejected. It may have expired." :
        res.status === 403 && remaining === "0" ? "GitHub rate limit reached. Try again after " + new Date(state.rate.reset).toLocaleTimeString() + "." :
        res.status === 403 ? "The token can't read this. Give it Administration: Read-only on pullyard/pullyard." :
        "GitHub returned " + res.status + ".");
      err.status = res.status;
      throw err;
    }
    return { body: await res.json(), link: res.headers.get("link") || "" };
  }

  async function paginate(path, accept, maxPages = 10) {
    let url = API + path + (path.includes("?") ? "&" : "?") + "per_page=100";
    const out = [];
    for (let i = 0; i < maxPages && url; i++) {
      const { body, link } = await gh(url, accept);
      out.push(...body);
      const next = link.split(",").find(p => p.includes('rel="next"'));
      url = next ? next.slice(next.indexOf("<") + 1, next.indexOf(">")) : null;
    }
    return out;
  }

  async function load() {
    if (state.loading) return;
    state.loading = true;
    const main = document.getElementById("main");
    const refresh = document.getElementById("refresh");
    main.setAttribute("aria-busy", "true");
    refresh.disabled = true;
    setBanner(null);

    const repoP = gh(`/repos/${REPO}`);
    const relP = paginate(`/repos/${REPO}/releases`);
    const starsP = state.token ? paginate(`/repos/${REPO}/stargazers`, "application/vnd.github.star+json") : Promise.resolve(null);
    const trafficP = state.token
      ? Promise.allSettled([
          gh(`/repos/${REPO}/traffic/views`),
          gh(`/repos/${REPO}/traffic/clones`),
          gh(`/repos/${REPO}/traffic/popular/referrers`),
          gh(`/repos/${REPO}/traffic/popular/paths`)
        ])
      : Promise.resolve(null);

    const [repo, rel, stars, traffic] = await Promise.allSettled([repoP, relP, starsP, trafficP]);
    state.loading = false;
    main.setAttribute("aria-busy", "false");
    refresh.disabled = false;

    if (state.token && repo.status === "rejected" && repo.reason.status === 401) {
      store.remove(KEYS.token);
      state.token = "";
      paintConnections();
      openSettings("github", repo.reason.message);
      load();
      return;
    }
    const failures = [repo, rel].filter(r => r.status === "rejected");
    if (failures.length) setBanner(failures[0].reason.message);

    const prev = state.data || {};
    const data = {
      repo: repo.status === "fulfilled" ? repo.value.body : prev.repo,
      agg: rel.status === "fulfilled" ? aggregate(rel.value) : prev.agg,
      stars: stars.status === "fulfilled" ? stars.value : prev.stars || null,
      traffic: null,
      trafficError: null
    };
    if (data.agg && rel.status === "fulfilled") data.snaps = recordSnapshot(data.agg);
    else data.snaps = prev.snaps || store.get(localStorage, KEYS.snaps, []);

    const t = traffic.status === "fulfilled" ? traffic.value : null;
    if (t) {
      const [views, clones, refs, paths] = t;
      if (views.status === "fulfilled" && clones.status === "fulfilled") {
        mergeTraffic("views", views.value.body.views);
        const all = mergeTraffic("clones", clones.value.body.clones);
        data.traffic = {
          views: views.value.body,
          clones: clones.value.body,
          history: all,
          referrers: refs.status === "fulfilled" ? refs.value.body : [],
          paths: paths.status === "fulfilled" ? paths.value.body : []
        };
      } else {
        data.trafficError = (views.reason || clones.reason).message;
      }
    }

    state.data = data;
    state.fetchedAt = Date.now();
    main.classList.add("has-data");
    render();
    loadSite();
  }

  function umamiConfig() {
    const cfg = store.get(localStorage, KEYS.umami, null);
    if (cfg && cfg.slug) return cfg;
    return cfg && cfg.id && cfg.key ? cfg : null;
  }

  function parseShareUrl(value) {
    const v = value.trim();
    const m = v.match(/^https:\/\/[^/]*umami[^/]*\/(?:.*\/)?share\/([a-zA-Z0-9]{8,50})(?:[/?#]|$)/) || (/[0-9]/.test(v) && /[a-zA-Z]/.test(v) ? v.match(/^([a-zA-Z0-9]{10,50})$/) : null);
    if (!m) return null;
    const region = (value.match(/\/analytics\/([a-z]{2})\//) || [])[1];
    return { slug: m[1], region: UMAMI_REGIONS.includes(region) ? region : null };
  }

  async function umamiFetch(url, headers) {
    const res = await fetch(url, { headers: { Accept: "application/json", ...headers }, cache: "no-store", referrerPolicy: "no-referrer" });
    if (!res.ok) {
      const err = new Error("Umami returned " + res.status + ".");
      err.status = res.status;
      throw err;
    }
    return res.json();
  }

  function shareSession(cfg, fresh) {
    if (!fresh && state.ws.share && state.ws.share.slug === cfg.slug) return state.ws.share.ready;
    const ready = fetchShare(cfg).catch(e => { if (state.ws.share && state.ws.share.ready === ready) state.ws.share = null; throw e; });
    state.ws.share = { slug: cfg.slug, ready };
    return ready;
  }

  async function openShare(region, slug) {
    const base = `${UMAMI_APP}/${region}/api`;
    try {
      const body = await umamiFetch(`${base}/share/${encodeURIComponent(slug)}`);
      return body.token && body.websiteId ? { region, base, websiteId: body.websiteId, token: body.token } : null;
    } catch (e) {
      if (e.status === 404) return null;
      throw e;
    }
  }

  async function hasTraffic(s) {
    try {
      const st = await umamiFetch(`${s.base}/websites/${s.websiteId}/stats?startAt=0&endAt=${Date.now()}`, { "x-umami-share-token": s.token, "x-umami-share-context": "1" });
      return num(st.pageviews) > 0;
    } catch (e) {
      return false;
    }
  }

  async function fetchShare(cfg) {
    if (cfg.region) {
      const s = await openShare(cfg.region, cfg.slug);
      if (s) return s;
    } else {
      const found = (await Promise.all(UMAMI_REGIONS.map(r => openShare(r, cfg.slug)))).filter(Boolean);
      for (const s of found) {
        if (await hasTraffic(s)) {
          store.set(localStorage, KEYS.umami, { ...cfg, region: s.region });
          return s;
        }
      }
      const fallback = found.find(s => s.region === "eu") || found[0];
      if (fallback) return fallback;
    }
    const err = new Error("Umami can't find that share link. Check that sharing is on for the website.");
    err.status = 404;
    throw err;
  }

  async function umami(cfg, path, params) {
    const qs = new URLSearchParams(params).toString();
    try {
      if (cfg.slug) {
        let s = await shareSession(cfg);
        try {
          return await umamiFetch(`${s.base}/websites/${s.websiteId}${path}?${qs}`, { "x-umami-share-token": s.token, "x-umami-share-context": "1" });
        } catch (e) {
          if (e.status !== 401) throw e;
          s = await shareSession(cfg, true);
          return await umamiFetch(`${s.base}/websites/${s.websiteId}${path}?${qs}`, { "x-umami-share-token": s.token, "x-umami-share-context": "1" });
        }
      }
      return await umamiFetch(`${UMAMI_API}/websites/${encodeURIComponent(cfg.id)}${path}?${qs}`, { Authorization: "Bearer " + cfg.key });
    } catch (e) {
      if (e.status === 401) e.message = cfg.slug ? "Umami rejected the share link." : "Umami rejected the API key.";
      else if (e.status === 404 && !cfg.slug) e.message = "Umami can't find that Website ID.";
      throw e;
    }
  }

  function siteWindow(days) {
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    start.setDate(start.getDate() - (days - 1));
    return { startAt: start.getTime(), endAt: Date.now() };
  }

  async function loadSite() {
    const cfg = umamiConfig();
    paintConnections();
    if (!cfg) {
      state.ws.data = null;
      state.ws.error = null;
      renderSite();
      renderOverview();
      return;
    }
    if (state.ws.loading) return;
    state.ws.loading = true;
    const panel = document.getElementById("panel-website");
    panel.setAttribute("aria-busy", "true");
    if (!state.ws.data) renderSite();
    const win = siteWindow(state.ws.range);
    const metric = (type, limit) => umami(cfg, "/metrics", { ...win, type, limit });
    try {
      const [stats, series, events, channels, referrers, countries, paths, sources, campaigns, os, browsers, devices] = await Promise.all([
        umami(cfg, "/stats", win),
        umami(cfg, "/pageviews", { ...win, unit: "day", timezone: TZ }),
        metric("event", 50),
        metric("channel", 20),
        metric("referrer", 10),
        metric("country", 10),
        metric("path", 10),
        metric("utmSource", 10),
        metric("utmCampaign", 10),
        metric("os", 6),
        metric("browser", 6),
        metric("device", 6)
      ]);
      state.ws.data = { stats, series, events, channels, referrers, countries, paths, sources, campaigns, os, browsers, devices, range: state.ws.range };
      state.ws.error = null;
    } catch (e) {
      state.ws.error = e;
      if (e.status === 401 || e.status === 404) state.ws.data = null;
    }
    state.ws.loading = false;
    panel.setAttribute("aria-busy", "false");
    paintConnections();
    renderSite();
    renderOverview();
  }

  const num = v => (v && typeof v === "object" ? Number(v.value) : Number(v)) || 0;
  const words = s => s.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, c => c.toUpperCase()).replace(/ (\w)/g, (m, c) => " " + c.toLowerCase());
  const CHANNEL_NAMES = { direct: "Direct", referral: "Other websites", organicSearch: "Search engines", organicSocial: "Social networks", organicVideo: "Video", organicShopping: "Shopping", email: "Email", sms: "SMS", paidAds: "Paid ads", paidSearch: "Paid search", paidSocial: "Paid social", paidVideo: "Paid video", paidShopping: "Paid shopping" };
  const BROWSER_NAMES = { "edge-chromium": "Edge", "edge-ios": "Edge", crios: "Chrome", fxios: "Firefox", ios: "Safari", "ios-webview": "Safari", samsung: "Samsung Internet", opera: "Opera", yandexbrowser: "Yandex" };
  const capFirst = s => (/^[a-z]/.test(s) ? s[0].toUpperCase() + s.slice(1).replace(/-/g, " ") : s);
  const duration = sec => {
    const s = Math.round(sec);
    if (s < 60) return s + "s";
    const m = Math.floor(s / 60);
    return m < 60 ? `${m}m ${s % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
  };

  const HELP = {
    downloads: ["Downloads", "How many times installer files were downloaded from GitHub Releases, across all versions. It includes auto-updates and Homebrew installs, so it's higher than the number of people."],
    mode: ["All downloads vs new installs", "All downloads counts every installer download. New installs only subtracts auto-updates (the app downloads a .sig file with each update). Homebrew installs can't be separated and stay in both."],
    newInstalls: ["New installs", "Installer downloads minus auto-updates. The closest estimate of new installs, though it still includes Homebrew and repeat downloads."],
    autoUpdates: ["Auto-updates", "Updates the app installed by itself. Each one downloads a signature file (.sig) from the release, which is what's counted here."],
    latest: ["Latest release", "Downloads of the newest version's files since it was published."],
    releases: ["Releases", "Number of published versions that have downloadable files."],
    siteVisitors: ["Website visitors", "Unique people who opened pullyard.github.io, counted by Umami without cookies. Your own local test visits aren't counted."],
    visits: ["Visits", "Sessions on the site. One visitor can come back several times."],
    pageviews: ["Page views", "Every page opened, including repeat views."],
    bounce: ["Bounce rate", "Share of visits that opened one page and left without another tracked action. Lower is better."],
    avgVisit: ["Average visit", "Average time between the first and last action in a visit."],
    downloadClicks: ["Download clicks", "Clicks on download buttons on the website. Each click starts a download from GitHub Releases."],
    repoVisitors: ["Repo visitors", "Unique GitHub users or browsers who opened the repository. GitHub only keeps the last 14 days."],
    cloners: ["Unique cloners", "Unique accounts or machines that ran git clone in the last 14 days."],
    stars: ["Stars", "People who starred the repository on GitHub."],
    forks: ["Forks", "Copies of the repository made on GitHub."]
  };

  function deltaText(cur, prev, invert) {
    if (!prev) return null;
    const change = Math.round(((cur - prev) / prev) * 100);
    if (!change) return { text: "No change", good: null };
    const better = invert ? change < 0 : change > 0;
    return { text: (change > 0 ? "↑ " : "↓ ") + Math.abs(change) + "%", good: better };
  }

  function helpButton(key) {
    return h("button", { class: "help", type: "button", "data-help": key, "aria-label": "About " + HELP[key][0].toLowerCase() }, "?");
  }

  function miniTiles(container, tiles) {
    container.replaceChildren(...tiles.map(t =>
      h("article", { class: "tile" + (t.locked ? " tile-locked" : "") },
        h("div", { class: "tile-head" }, h("h3", { class: "tile-label" }, t.label), t.help ? helpButton(t.help) : null),
        h("p", { class: "tile-value" }, t.value),
        h("p", { class: "tile-sub" }, t.delta ? [h("span", { class: t.delta.good ? "delta" : null }, t.delta.text), " " + (t.deltaLabel || "")] : t.sub || ""))));
  }

  function showEmpty(box, cfg) {
    box.hidden = false;
    box.replaceChildren(
      h("div", { class: "empty-icon", "aria-hidden": "true" }, cfg.icon || "i"),
      h("div", null,
        h("h3", null, cfg.title),
        h("p", null, cfg.text),
        cfg.action ? h("button", { class: "btn btn-primary btn-sm", type: "button", onclick: cfg.action[1] }, cfg.action[0]) : null));
  }

  function lockedValue(text, section) {
    return h("button", { class: "connect-link", type: "button", onclick: () => openSettings(section) }, text);
  }

  function siteSummary() {
    const d = state.ws.data;
    if (!d) return null;
    const st = d.stats, cmp = st.comparison || {};
    const clicks = d.events.filter(e => /^download-(macos|windows|linux)$/.test(e.x)).reduce((a, e) => a + num(e.y), 0);
    return { st, cmp, clicks, visitors: num(st.visitors), pageviews: num(st.pageviews) };
  }

  function renderSite() {
    const cfg = umamiConfig();
    const d = state.ws.data;
    const emptyBox = document.getElementById("ws-empty");
    const body = document.getElementById("ws-body");
    document.querySelectorAll("#ws-range button").forEach(b => { b.disabled = !cfg; });
    if (!cfg) {
      body.hidden = true;
      return showEmpty(emptyBox, { icon: "↗", title: "Connect Umami to see website visitors", text: "See who visits pullyard.github.io, where they come from, their countries and how many click Download. Free Umami plan works through a share link.", action: ["Connect Umami", () => openSettings("umami")] });
    }
    if (state.ws.error && !d) {
      body.hidden = true;
      return showEmpty(emptyBox, { icon: "!", title: "Couldn't load website stats", text: state.ws.error.message, action: ["Check connection", () => openSettings("umami", state.ws.error.message)] });
    }
    if (!d) {
      body.hidden = true;
      return showEmpty(emptyBox, { icon: "…", title: "Loading website stats", text: "Asking Umami for the last " + state.ws.range + " days." });
    }
    const sum = siteSummary();
    if (!sum.pageviews) {
      body.hidden = true;
      return showEmpty(emptyBox, { icon: "0", title: `No visits in the last ${d.range} days`, text: "Umami is connected. Visits show up after the site with docs/site/analytics.js is live on pullyard.github.io. Visits from localhost aren't counted." });
    }
    emptyBox.hidden = true;
    body.hidden = false;

    const { st, cmp, clicks } = sum;
    const visits = num(st.visits), prevVisits = num(cmp.visits);
    const vs = `vs prior ${d.range} days`;
    miniTiles(document.getElementById("ws-kpis"), [
      { label: "Visitors", help: "siteVisitors", value: nf.format(sum.visitors), delta: deltaText(sum.visitors, num(cmp.visitors)), deltaLabel: vs },
      { label: "Visits", help: "visits", value: nf.format(visits), delta: deltaText(visits, prevVisits), deltaLabel: vs },
      { label: "Page views", help: "pageviews", value: nf.format(sum.pageviews), delta: deltaText(sum.pageviews, num(cmp.pageviews)), deltaLabel: vs },
      { label: "Bounce rate", help: "bounce", value: visits ? Math.round((num(st.bounces) / visits) * 100) + "%" : "–", delta: prevVisits && visits ? deltaText(num(st.bounces) / visits, num(cmp.bounces) / prevVisits, true) : null, deltaLabel: vs },
      { label: "Average visit", help: "avgVisit", value: visits ? duration(num(st.totaltime) / visits) : "–", delta: prevVisits && visits ? deltaText(num(st.totaltime) / visits, num(cmp.totaltime) / prevVisits) : null, deltaLabel: vs },
      { label: "Download clicks", help: "downloadClicks", value: nf.format(clicks), sub: sum.visitors ? `${Math.round((clicks / sum.visitors) * 100)} per 100 visitors` : "" }
    ]);

    const tc = card("ws-traffic");
    const days = [];
    const first = new Date(siteWindow(d.range).startAt);
    for (let i = 0; i < d.range; i++) {
      const dt = new Date(first.getFullYear(), first.getMonth(), first.getDate() + i);
      days.push(`${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`);
    }
    const byDay = list => { const m = {}; for (const p of list || []) m[String(p.x).slice(0, 10)] = num(p.y); return m; };
    const pv = byDay(d.series.pageviews), ss = byDay(d.series.sessions);
    const series = [
      { name: "Page views", color: "var(--c1)", values: days.map(k => pv[k] || 0) },
      { name: "Visits", color: "var(--c2)", values: days.map(k => ss[k] || 0) }
    ];
    const label = k => ({ short: shortDate(k + "T00:00:00Z"), long: longDate(k + "T00:00:00Z") });
    tc.chart.replaceChildren();
    const host = h("div");
    tc.chart.append(legend(series, "line"), host);
    lineChart(host, { height: 240, ariaLabel: "Website page views and visits per day. Use arrow keys to move between days.", labels: days.map(label), series });
    table(tc.table, [{ key: "d", label: "Date" }, { key: "pv", label: "Page views", num: true }, { key: "v", label: "Visits", num: true }],
      [...days].reverse().map(k => ({ d: label(k).long, pv: pv[k] || 0, v: ss[k] || 0 })));

    const dc = card("ws-downloads");
    const dlRows = DOWNLOAD_PLATFORMS.map(p => {
      const v = num((d.events.find(e => e.x === "download-" + p.id) || {}).y);
      return { label: p.name, color: p.color, value: v, sub: pct(v, clicks) };
    });
    const actions = d.events.filter(e => ACTION_NAMES[e.x]).map(e => ({ label: ACTION_NAMES[e.x], value: num(e.y) })).sort((a, b) => b.value - a.value);
    dc.chart.replaceChildren();
    const dlHost = h("div"), actHost = h("div");
    dc.chart.append(dlHost);
    if (clicks) hbars(dlHost, dlRows);
    else empty(dlHost, "No download clicks yet");
    if (actions.length) {
      dc.chart.append(h("h4", { class: "sub-h" }, "Other clicks"), actHost);
      hbars(actHost, actions, "var(--muted)");
    }

    const rows = (list, name) => list.filter(e => e.x).map(e => ({ label: name ? name(e.x) : e.x, value: num(e.y) }));
    hbars(card("ws-channels").chart, rows(d.channels, x => CHANNEL_NAMES[x] || words(x)).sort((a, b) => b.value - a.value), "var(--c1)");
    hbars(card("ws-referrers").chart, rows(d.referrers), "var(--c1)");
    hbars(card("ws-countries").chart, rows(d.countries, countryName), "var(--c1)");

    const pc = card("ws-pages");
    if (!d.paths.length) empty(pc.table, "No page views yet");
    else table(pc.table, [{ key: "p", label: "Page", cls: "path" }, { key: "v", label: "Views", num: true }], d.paths.map(e => ({ p: e.x || "/", v: num(e.y) })));

    const cc = card("ws-campaigns");
    const src = rows(d.sources), camp = rows(d.campaigns);
    cc.chart.replaceChildren();
    if (!src.length && !camp.length) {
      empty(cc.chart, "No tagged visits yet. Add ?utm_source=linkedin&utm_campaign=launch to links you share.");
    } else {
      const a = h("div"), b = h("div");
      cc.chart.append(h("h4", { class: "sub-h first" }, "Source"), a, h("h4", { class: "sub-h" }, "Campaign"), b);
      hbars(a, src, "var(--c1)");
      hbars(b, camp, "var(--c1)");
    }

    const tech = card("ws-tech").chart;
    tech.replaceChildren();
    for (const [title, list, name] of [["Operating system", d.os, capFirst], ["Browser", d.browsers, x => BROWSER_NAMES[x] || capFirst(x)], ["Device", d.devices, capFirst]]) {
      const box = h("div");
      tech.append(h("div", null, h("h4", { class: "sub-h" }, title), box));
      hbars(box, rows(list, name), "var(--muted)");
    }
  }

  function countryName(code) {
    try { return (regionNames && regionNames.of(code)) || code; } catch (e) { return code; }
  }

  function setBanner(text) {
    const b = document.getElementById("banner");
    b.hidden = !text;
    b.textContent = text || "";
  }

  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  function setNode(id, ...kids) {
    const el = document.getElementById(id);
    if (el) { el.replaceChildren(); append(el, kids); }
  }

  function card(name) {
    const el = document.querySelector(`[data-card="${name}"]`);
    return { el, chart: el.querySelector("[data-chart]"), table: el.querySelector("[data-table]"), list: el.querySelector("[data-list]") };
  }

  function render() {
    const d = state.data;
    if (!d) return;
    renderOverview();
    renderDownloads(d);
    renderGithub(d);
    renderSite();
    renderMeta();
  }

  function connectionState() {
    const cfg = umamiConfig();
    const d = state.data;
    return {
      github: !state.token ? "off" : d && d.traffic ? "on" : d && d.trafficError ? "error" : "pending",
      umami: !cfg ? "off" : state.ws.error && !state.ws.data ? "error" : state.ws.data ? "on" : "pending",
      siteLive: !!(siteSummary() && siteSummary().pageviews)
    };
  }

  function renderOverview() {
    const d = state.data;
    const conn = connectionState();
    const sum = siteSummary();

    const steps = [
      { done: true, label: "Downloads and stars", text: "Public GitHub data, always on." },
      { done: conn.github === "on", label: "GitHub token", text: "Repo visitors, clones and stargazers.", action: ["Add token", () => openSettings("github")] },
      { done: conn.umami === "on", label: "Umami share link", text: "Website visitors, sources and countries.", action: ["Connect", () => openSettings("umami")] },
      { done: conn.siteLive, label: "Tracking on the live site", text: "Deploy the site with analytics.js. Visits appear within minutes.", action: null }
    ];
    const setup = document.getElementById("setup");
    setup.hidden = steps.every(s => s.done);
    document.getElementById("setup-steps").replaceChildren(...steps.map(s =>
      h("li", { class: s.done ? "done" : null },
        h("span", { class: "step-mark", "aria-hidden": "true" }, s.done ? "✓" : ""),
        h("div", null, h("b", null, s.label), h("span", null, s.done ? " · done" : ""), h("p", null, s.text)),
        !s.done && s.action ? h("button", { class: "btn btn-ghost btn-sm", type: "button", onclick: s.action[1] }, s.action[0]) : null)));

    if (d && d.agg) {
      const total = totalFor(d.agg.dl, d.agg.up, "all");
      setText("o-downloads", nf.format(total));
      const snaps = d.snaps || [];
      const prior = snaps.length > 1 ? snaps[snaps.length - 2] : null;
      const est = totalFor(d.agg.dl, d.agg.up, "net");
      if (prior) {
        const diff = total - totalFor(prior.dl, prior.up, "all");
        setNode("o-downloads-sub", h("span", { class: "delta" }, (diff >= 0 ? "+" : "") + nf.format(diff)), ` since ${shortDate(prior.d)} · about ${nf.format(est)} new installs`);
      } else {
        setText("o-downloads-sub", `About ${nf.format(est)} new installs, the rest are auto-updates`);
      }
      const spark = document.getElementById("o-spark");
      if (snaps.length > 1) lineChart(spark, { compact: true, height: 56, area: true, labels: snaps.map(x => ({ short: shortDate(x.d), long: longDate(x.d) })), series: [{ name: "Downloads", color: "var(--c1)", values: snaps.map(x => totalFor(x.dl, x.up, "all")) }] });
      else spark.replaceChildren();

      const plat = card("o-platforms");
      const platBox = h("div"), kindBox = h("div");
      plat.chart.replaceChildren(platBox, h("h4", { class: "sub-h" }, "What the downloads are"), kindBox);
      hbars(platBox, PLATFORMS.map(p => ({ label: p.name, color: p.color, value: d.agg.dl[p.id], sub: pct(d.agg.dl[p.id], total) })));
      hbars(kindBox, [{ label: "New installs", value: est, sub: pct(est, total) }, { label: "Auto-updates", value: total - est, sub: pct(total - est, total) }], "var(--muted)");
      plat.chart.append(h("button", { class: "goto", type: "button", "data-goto": "downloads" }, "By release and file ", h("span", { "aria-hidden": "true" }, "→")));
    }

    if (sum) {
      setText("o-visitors", nf.format(sum.visitors));
      const dv = deltaText(sum.visitors, num(sum.cmp.visitors));
      setNode("o-visitors-sub", dv ? [h("span", { class: dv.good ? "delta" : null }, dv.text), " vs prior 30 days"] : `${nf.format(sum.pageviews)} page views`);
      setText("o-clicks", nf.format(sum.clicks));
      setText("o-clicks-sub", sum.visitors ? `${Math.round((sum.clicks / sum.visitors) * 100)} per 100 visitors` : "");
    } else {
      const text = conn.umami === "off" ? "Connect Umami" : conn.umami === "error" ? "Fix connection" : "Loading…";
      for (const id of ["o-visitors", "o-clicks"]) setNode(id, conn.umami === "pending" ? h("span", { class: "skel" }) : lockedValue(text, "umami"));
      setText("o-visitors-sub", "");
      setText("o-clicks-sub", "");
    }

    if (d && d.traffic) {
      setText("o-repo", nf.format(d.traffic.views.uniques));
      setText("o-repo-sub", `${nf.format(d.traffic.views.count)} views`);
    } else if (d) {
      setNode("o-repo", lockedValue(state.token ? "Fix token" : "Add GitHub token", "github"));
      setText("o-repo-sub", "");
    }

    if (d && d.repo) {
      setText("o-stars", nf.format(d.repo.stargazers_count));
      const recent = d.stars ? d.stars.filter(x => Date.now() - Date.parse(x.starred_at) < 14 * DAY_MS).length : null;
      setText("o-stars-sub", recent == null ? `${nf.format(d.repo.forks_count)} forks` : recent ? `+${recent} in the last 14 days` : "None new in 14 days");
    }

    const sc = card("o-sources");
    sc.chart.replaceChildren();
    const ws = state.ws.data;
    if (sum && sum.pageviews) {
      setText("o-sources-sub", "Website visitors by channel · 30 days");
      const box = h("div");
      sc.chart.append(box);
      hbars(box, ws.channels.filter(e => e.x).map(e => ({ label: CHANNEL_NAMES[e.x] || words(e.x), value: num(e.y) })).sort((a, b) => b.value - a.value).slice(0, 6), "var(--c1)");
      if (ws.countries.length) {
        sc.chart.append(h("h4", { class: "sub-h" }, "Top countries"));
        const c = h("div");
        sc.chart.append(c);
        hbars(c, ws.countries.filter(e => e.x).slice(0, 4).map(e => ({ label: countryName(e.x), value: num(e.y) })), "var(--muted)");
      }
      sc.chart.append(h("button", { class: "goto", type: "button", "data-goto": "website" }, "All website stats ", h("span", { "aria-hidden": "true" }, "→")));
    } else if (d && d.traffic && d.traffic.referrers.length) {
      setText("o-sources-sub", "Sites that sent people to the GitHub repo · 14 days");
      const box = h("div");
      sc.chart.append(box);
      hbars(box, d.traffic.referrers.slice(0, 6).map(r => ({ label: r.referrer, value: r.count, sub: `${nf.format(r.uniques)} unique` })), "var(--c1)");
      sc.chart.append(h("p", { class: "note-inline" }, "Website sources appear here once Umami has visits."));
    } else {
      setText("o-sources-sub", "");
      const box = h("div", { class: "empty-state compact" });
      sc.chart.append(box);
      showEmpty(box, conn.umami === "off"
        ? { icon: "↗", title: "No source data yet", text: "Connect Umami to see where website visitors come from.", action: ["Connect Umami", () => openSettings("umami")] }
        : { icon: "0", title: "No source data yet", text: "Sources appear after the first visits to the live site." });
    }
  }

  function renderDownloads(d) {
    if (!d.agg) return;
    const mode = state.dlMode;
    const { dl, up, rows, formats } = d.agg;
    const total = totalFor(dl, up, mode);
    const updates = PLATFORMS.reduce((a, p) => a + up[p.id], 0);
    const latest = [...rows].reverse().find(r => !r.pre && PLATFORMS.some(p => r.dl[p.id] > 0));
    const shown = rows.filter(r => PLATFORMS.some(p => r.dl[p.id] > 0)).length;

    miniTiles(document.getElementById("d-kpis"), [
      { label: mode === "net" ? "New installs" : "All downloads", help: mode === "net" ? "newInstalls" : "downloads", value: nf.format(total), sub: `${shown} releases` },
      { label: "Latest release", help: "latest", value: latest ? nf.format(totalFor(latest.dl, latest.up, mode)) : "–", sub: latest ? `v${latest.tag} · ${ago(Date.parse(latest.date))}` : "" },
      { label: "Auto-updates", help: "autoUpdates", value: nf.format(updates), sub: "Installed by the app itself" },
      { label: "Top platform", help: null, value: (() => { const best = PLATFORMS.map(p => [p, countFor(dl, up, p.id, mode)]).sort((a, b) => b[1] - a[1])[0]; return best ? best[0].name : "–"; })(), sub: (() => { const best = PLATFORMS.map(p => countFor(dl, up, p.id, mode)).sort((a, b) => b - a)[0]; return pct(best, total) + " of downloads"; })() }
    ]);

    const pc = card("platforms");
    const platRows = PLATFORMS.map(p => ({ label: p.name, color: p.color, value: countFor(dl, up, p.id, mode), sub: pct(countFor(dl, up, p.id, mode), total) }));
    const archTotals = new Map();
    for (const f of formats) {
      const label = f.arch || "Other";
      archTotals.set(label, (archTotals.get(label) || 0) + (mode === "net" ? Math.max(0, f.downloads - f.updates) : f.downloads));
    }
    const archRows = [...archTotals].map(([label, value]) => ({ label, value, sub: pct(value, total) })).sort((a, b) => b.value - a.value);
    pc.chart.replaceChildren();
    const platHost = h("div"), archHost = h("div");
    pc.chart.append(platHost, h("h4", { class: "sub-h" }, "By processor"), archHost);
    hbars(platHost, platRows);
    hbars(archHost, archRows, "var(--muted)");
    setText("platforms-sub", mode === "net" ? "New installs, auto-updates subtracted" : "Every installer download");
    table(pc.table, [
      { key: "name", label: "Platform" },
      { key: "dl", label: "All downloads", num: true },
      { key: "up", label: "Auto-updates", num: true },
      { key: "net", label: "New installs", num: true },
      { key: "share", label: "Share", num: true }
    ], PLATFORMS.map(p => ({ name: p.name, dl: dl[p.id], up: up[p.id], net: net(dl, up, p.id), share: pct(countFor(dl, up, p.id, mode), total) })));

    const hc = card("history");
    const snaps = d.snaps || [];
    if (snaps.length < 2) {
      empty(hc.chart, "The trend starts today. Open this page again tomorrow to see it grow.");
    } else {
      const days = dailyRange(snaps[0].d, snaps[snaps.length - 1].d);
      const byDay = Object.fromEntries(snaps.map(x => [x.d, x]));
      hc.chart.replaceChildren();
      const host = h("div");
      hc.chart.append(legend(PLATFORMS, "line"), host);
      lineChart(host, {
        height: 220,
        connectGaps: true,
        ariaLabel: "Total downloads per platform over time. Use arrow keys to move between days.",
        labels: days.map(k => ({ short: shortDate(k), long: longDate(k) })),
        series: PLATFORMS.map(p => ({ name: p.name, color: p.color, values: days.map(k => (byDay[k] ? countFor(byDay[k].dl, byDay[k].up, p.id, mode) : null)) }))
      });
    }
    table(hc.table, [
      { key: "d", label: "Date" },
      ...PLATFORMS.map(p => ({ key: p.id, label: p.name, num: true })),
      { key: "total", label: "Total", num: true }
    ], [...snaps].reverse().map(x => ({ d: longDate(x.d), ...Object.fromEntries(PLATFORMS.map(p => [p.id, countFor(x.dl, x.up, p.id, mode)])), total: totalFor(x.dl, x.up, mode) })));

    const rc = card("releases");
    const visible = rows.filter(r => PLATFORMS.some(p => r.dl[p.id] > 0));
    stackedColumns(rc.chart, {
      ariaLabel: "Downloads per release, stacked by platform",
      cats: visible.map(r => ({ short: r.tag, long: `v${r.tag} · ${shortDate(r.date)}${r.pre ? " · pre-release" : ""}` })),
      series: PLATFORMS.map(p => ({ name: p.name, color: p.color, values: visible.map(r => countFor(r.dl, r.up, p.id, mode)) }))
    });
    table(rc.table, [
      { key: "tag", label: "Version" },
      { key: "date", label: "Published" },
      ...PLATFORMS.map(p => ({ key: p.id, label: p.name, num: true })),
      { key: "total", label: "Total", num: true },
      { key: "updates", label: "Auto-updates", num: true }
    ], [...visible].reverse().map(r => ({
      tag: h("a", { href: r.url, target: "_blank", rel: "noopener noreferrer" }, "v" + r.tag),
      date: shortDate(r.date),
      ...Object.fromEntries(PLATFORMS.map(p => [p.id, countFor(r.dl, r.up, p.id, mode)])),
      total: totalFor(r.dl, r.up, mode),
      updates: PLATFORMS.reduce((a, p) => a + r.up[p.id], 0)
    })));

    const fc = card("formats");
    const fRows = formats
      .map(f => ({ ...f, count: mode === "net" ? Math.max(0, f.downloads - f.updates) : f.downloads }))
      .filter(f => f.downloads > 0 || f.updates > 0)
      .sort((a, b) => b.count - a.count);
    const fTotal = fRows.reduce((a, f) => a + f.count, 0);
    table(fc.table, [
      { key: "platform", label: "Platform" },
      { key: "format", label: "Format" },
      { key: "arch", label: "Processor" },
      { key: "count", label: mode === "net" ? "New installs" : "Downloads", num: true },
      { key: "updates", label: "Auto-updates", num: true },
      { key: "share", label: "Share", num: true }
    ], fRows.map(f => {
      const p = PLATFORMS.find(x => x.id === f.platform);
      return {
        platform: h("span", { class: "cell" }, h("i", { class: "key-dot", style: { background: p.color } }), p.name),
        format: f.format,
        arch: f.arch || "–",
        count: f.count,
        updates: f.updates,
        share: pct(f.count, fTotal)
      };
    }));
  }

  function renderGithub(d) {
    const locked = !d.traffic;
    const emptyBox = document.getElementById("gh-empty");
    document.getElementById("gh-traffic").hidden = locked;
    if (locked) {
      showEmpty(emptyBox, state.token
        ? { icon: "!", title: "Traffic isn't available", text: d.trafficError || "GitHub didn't return traffic for this token.", action: ["Check token", () => openSettings("github", d.trafficError)] }
        : { icon: "↗", title: "Add a GitHub token to see repo traffic", text: "GitHub only shows views, clones, referring sites and stargazers to people who can push to the repo. A read-only token is enough.", action: ["Add token", () => openSettings("github")] });
    } else {
      emptyBox.hidden = true;
    }

    const repo = d.repo || {};
    const recent = d.stars ? d.stars.filter(x => Date.now() - Date.parse(x.starred_at) < 14 * DAY_MS).length : null;
    miniTiles(document.getElementById("g-kpis"), [
      d.traffic
        ? { label: "Repo visitors · 14 days", help: "repoVisitors", value: nf.format(d.traffic.views.uniques), sub: `${nf.format(d.traffic.views.count)} views` }
        : { label: "Repo visitors · 14 days", help: "repoVisitors", value: "–", sub: "Needs a token", locked: true },
      d.traffic
        ? { label: "Unique cloners · 14 days", help: "cloners", value: nf.format(d.traffic.clones.uniques), sub: `${nf.format(d.traffic.clones.count)} clones` }
        : { label: "Unique cloners · 14 days", help: "cloners", value: "–", sub: "Needs a token", locked: true },
      { label: "Stars", help: "stars", value: nf.format(repo.stargazers_count || 0), sub: recent == null ? `${nf.format(repo.subscribers_count || 0)} watching` : recent ? `+${recent} in the last 14 days` : "None new in 14 days" },
      { label: "Forks", help: "forks", value: nf.format(repo.forks_count || 0), sub: `${nf.format(repo.open_issues_count || 0)} open issues` }
    ]);

    if (!locked) {
      const kind = state.kind;
      const hist = d.traffic.history[kind] || {};
      const keys = Object.keys(hist).sort();
      const today = dayKey(Date.now());
      const first = state.range ? dayKey(Date.now() - (state.range - 1) * DAY_MS) : keys[0] || today;
      const days = dailyRange(first, today);
      const apiDays = new Set((d.traffic[kind][kind] || []).map(v => dayKey(v.timestamp)));
      const apiFrom = [...apiDays].sort()[0];
      const valueAt = (k, f) => (hist[k] ? hist[k][f] : apiFrom && k >= apiFrom ? 0 : null);
      const totalName = kind === "views" ? "Views" : "Clones";
      const uniqName = kind === "views" ? "Unique visitors" : "Unique cloners";
      setText("traffic-title", totalName);

      const tc = card("traffic");
      tc.chart.replaceChildren();
      const series = [
        { name: totalName, color: "var(--c1)", values: days.map(k => valueAt(k, "c")) },
        { name: uniqName, color: "var(--c2)", values: days.map(k => valueAt(k, "u")) }
      ];
      const host = h("div");
      tc.chart.append(legend(series, "line"), host);
      lineChart(host, { height: 240, ariaLabel: `${totalName} and ${uniqName.toLowerCase()} per day. Use arrow keys to move between days.`, labels: days.map(k => ({ short: shortDate(k), long: longDate(k) })), series });
      table(tc.table, [{ key: "d", label: "Date" }, { key: "c", label: totalName, num: true }, { key: "u", label: uniqName, num: true }],
        [...days].reverse().map(k => ({ d: longDate(k), c: valueAt(k, "c"), u: valueAt(k, "u") })));

      hbars(card("referrers").chart, d.traffic.referrers.slice(0, 10).map(r => ({ label: r.referrer, value: r.count, sub: `${nf.format(r.uniques)} unique` })), "var(--c1)");

      const pc = card("paths");
      if (!d.traffic.paths.length) empty(pc.table, "No page views in the last 14 days");
      else table(pc.table, [
        { key: "path", label: "Page", cls: "path" },
        { key: "count", label: "Views", num: true },
        { key: "uniques", label: "Unique", num: true }
      ], d.traffic.paths.map(p => ({
        path: h("a", { href: "https://github.com" + p.path, target: "_blank", rel: "noopener noreferrer", title: p.title }, p.path.replace("/" + REPO, "") || "/"),
        count: p.count,
        uniques: p.uniques
      })));
    }

    renderCommunity(d);
  }

  function renderCommunity(d) {
    const sc = card("stars");
    const lc = card("stargazers");
    if (d.repo) setText("repo-facts", `${nf.format(d.repo.forks_count)} forks · ${nf.format(d.repo.subscribers_count)} watching`);
    if (!d.stars) {
      const why = state.token ? "GitHub didn't return the stargazer list." : "GitHub only lists stargazers to signed-in requests. Add a token to see who starred.";
      empty(sc.chart, why);
      sc.table.replaceChildren();
      empty(lc.list, why);
      return;
    }
    const stars = [...d.stars].sort((a, b) => Date.parse(a.starred_at) - Date.parse(b.starred_at));
    if (d.repo) {
      const from = dayKey(d.repo.created_at);
      const days = dailyRange(from, dayKey(Date.now()));
      let i = 0, cum = 0;
      const values = days.map(k => { while (i < stars.length && dayKey(stars[i].starred_at) <= k) { cum++; i++; } return cum; });
      lineChart(sc.chart, { height: 220, area: true, ariaLabel: "Total stars per day. Use arrow keys to move between days.", labels: days.map(k => ({ short: shortDate(k), long: longDate(k) })), series: [{ name: "Stars", color: "var(--c1)", values }] });
      setText("stars-sub", `Since the repo was created on ${shortDate(d.repo.created_at)}`);
      table(sc.table, [{ key: "d", label: "Date" }, { key: "who", label: "Starred by" }, { key: "n", label: "Total", num: true }],
        stars.map((x, k) => ({ d: longDate(x.starred_at), who: x.user.login, n: k + 1 })).reverse());
    }
    const latest = stars.slice(-8).reverse();
    if (!latest.length) return empty(lc.list, "No stars yet");
    lc.list.replaceChildren(h("ul", { class: "people" }, latest.map(x =>
      h("li", null, h("a", { href: x.user.html_url, target: "_blank", rel: "noopener noreferrer" },
        h("img", { src: x.user.avatar_url + (x.user.avatar_url.includes("?") ? "&" : "?") + "s=60", alt: "", width: 30, height: 30, loading: "lazy" }),
        h("span", { class: "who" }, x.user.login),
        h("span", { class: "when", title: longDate(x.starred_at) }, ago(Date.parse(x.starred_at))))))));
  }

  function renderMeta() {
    const el = document.getElementById("updated");
    if (state.fetchedAt) {
      const stale = Date.now() - state.fetchedAt > STALE_MS;
      el.classList.toggle("stale", stale);
      el.replaceChildren(h("i", { class: "pulse" }), (stale ? "Stale · updated " : "Updated ") + ago(state.fetchedAt));
    }
    const foot = document.getElementById("foot");
    const parts = ["Data from the GitHub API and Umami."];
    if (state.rate) parts.push(`GitHub API calls left: ${nf.format(state.rate.remaining)} of ${nf.format(state.rate.limit)}, resets ${new Date(state.rate.reset).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}.`);
    foot.textContent = parts.join(" ");
  }

  function paintConnections() {
    const conn = connectionState();
    const label = { on: "Connected", off: "Not connected", error: "Needs attention", pending: "Checking…" };
    for (const [id, key] of [["gh-status", "github"], ["um-status", "umami"]]) {
      const pill = document.getElementById(id);
      pill.textContent = label[conn[key]];
      pill.dataset.state = conn[key];
    }
    document.getElementById("gh-remove").hidden = !state.token;
    document.getElementById("ws-disconnect").hidden = !umamiConfig();
    const missing = ["github", "umami"].filter(k => conn[k] === "off" || conn[k] === "error").length;
    const badge = document.getElementById("conn-badge");
    badge.hidden = !missing;
    badge.textContent = missing;
    document.getElementById("open-settings").setAttribute("aria-label", missing ? `Connections, ${missing} not set up` : "Connections");
    document.querySelector("#tab-website .tab-dot").hidden = conn.umami === "on" || conn.umami === "pending";
    document.querySelector("#tab-github .tab-dot").hidden = conn.github === "on" || conn.github === "pending";
  }

  function fieldError(id, text) {
    const el = document.getElementById(id);
    el.hidden = !text;
    el.textContent = text || "";
  }

  function openSettings(section, error) {
    const dlg = document.getElementById("settings");
    const cfg = store.get(localStorage, KEYS.umami, null);
    document.getElementById("gh-token").value = "";
    document.getElementById("gh-token").placeholder = state.token ? "Saved. Paste a new token to replace it" : "github_pat_…";
    document.getElementById("ws-share").value = cfg && cfg.url ? cfg.url : "";
    document.getElementById("ws-id").value = cfg && cfg.id ? cfg.id : "";
    document.getElementById("ws-key").value = "";
    document.getElementById("ws-key").placeholder = cfg && cfg.key ? "Saved. Paste a new key to replace it" : "";
    document.getElementById("ws-pro").open = !!(cfg && cfg.key);
    fieldError("gh-error", section === "github" ? error : null);
    fieldError("ws-error", section === "umami" ? error : null);
    paintConnections();
    if (!dlg.open) dlg.showModal();
    const target = section === "umami" ? document.getElementById("ws-share") : section === "github" ? document.getElementById("gh-token") : null;
    if (target) {
      target.closest("form").scrollIntoView({ block: "nearest" });
      target.focus();
    }
  }

  function closeSettings() {
    const dlg = document.getElementById("settings");
    if (dlg.open) dlg.close();
  }

  const TABS = ["overview", "website", "downloads", "github"];

  function selectTab(name, opts = {}) {
    if (!TABS.includes(name)) name = "overview";
    state.tab = name;
    for (const t of TABS) {
      const btn = document.getElementById("tab-" + t);
      const on = t === name;
      btn.setAttribute("aria-selected", String(on));
      btn.tabIndex = on ? 0 : -1;
      document.getElementById("panel-" + t).hidden = !on;
    }
    if (opts.push !== false && location.hash !== "#" + name) history.replaceState(null, "", "#" + name);
    tip.hide();
    render();
    if (opts.focusTab) document.getElementById("tab-" + name).focus();
    if (opts.focusPanel) document.getElementById("panel-" + name).focus({ preventScroll: true });
    if (opts.scroll) window.scrollTo({ top: 0 });
  }

  function bindSeg(id, key, cast, after) {
    const root = document.getElementById(id);
    const buttons = [...root.querySelectorAll("button")];
    const select = b => {
      buttons.forEach(x => x.setAttribute("aria-checked", String(x === b)));
      buttons.forEach(x => x.tabIndex = x === b ? 0 : -1);
      state[key] = cast(b.dataset.value);
      after();
    };
    buttons.forEach((b, i) => {
      b.tabIndex = b.getAttribute("aria-checked") === "true" ? 0 : -1;
      b.addEventListener("click", () => select(b));
      b.addEventListener("keydown", e => {
        const dir = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
        if (!dir) return;
        e.preventDefault();
        const next = buttons[(i + dir + buttons.length) % buttons.length];
        next.focus();
        select(next);
      });
    });
  }

  function skeleton() {
    for (const id of ["o-downloads", "o-visitors", "o-clicks", "o-repo", "o-stars"]) setNode(id, h("span", { class: "skel" }));
  }

  function showHelp(btn) {
    const entry = HELP[btn.dataset.help];
    if (!entry) return;
    const r = btn.getBoundingClientRect();
    tip.text(r.left + r.width / 2, r.top, entry[0], entry[1]);
  }

  function init() {
    tip.el = document.getElementById("tip");
    tip.text = function (px, py, title, body) {
      const el = this.el;
      el.replaceChildren(h("p", { class: "tip-title" }, title), h("p", { class: "tip-body" }, body));
      el.classList.add("tip-help");
      el.hidden = false;
      const w = el.offsetWidth, ht = el.offsetHeight;
      let x = Math.min(Math.max(8, px - w / 2), window.innerWidth - w - 8);
      let y = py - ht - 10;
      if (y < 8) y = py + 30;
      el.style.left = x + "px";
      el.style.top = y + "px";
    };
    const baseShow = tip.show.bind(tip);
    tip.show = (...args) => { tip.el.classList.remove("tip-help"); baseShow(...args); };

    state.token = readToken();

    const themeBtn = document.getElementById("theme");
    const paintTheme = () => {
      const pref = themePref();
      themeBtn.dataset.pref = pref;
      themeBtn.setAttribute("aria-label", "Theme: " + pref);
      themeBtn.title = "Theme: " + pref;
    };
    paintTheme();
    themeBtn.addEventListener("click", () => {
      const next = { auto: "light", light: "dark", dark: "auto" }[themePref()];
      try { if (next === "auto") localStorage.removeItem(KEYS.theme); else localStorage.setItem(KEYS.theme, next); } catch (e) {}
      applyTheme(next);
      paintTheme();
    });

    const tabs = document.getElementById("tabs");
    tabs.addEventListener("click", e => {
      const b = e.target.closest("[data-tab]");
      if (b) selectTab(b.dataset.tab);
    });
    tabs.addEventListener("keydown", e => {
      const i = TABS.indexOf(state.tab);
      const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: TABS.length - 1 }[e.key];
      if (next == null) return;
      e.preventDefault();
      selectTab(TABS[(next + TABS.length) % TABS.length], { focusTab: true });
    });
    window.addEventListener("hashchange", () => selectTab(location.hash.slice(1), { push: false }));

    document.addEventListener("click", e => {
      const go = e.target.closest("[data-goto]");
      if (go) selectTab(go.dataset.goto, { focusPanel: true, scroll: true });
    });

    document.addEventListener("pointerover", e => { const b = e.target.closest(".help"); if (b) showHelp(b); });
    document.addEventListener("pointerout", e => { if (e.target.closest(".help")) tip.hide(); });
    document.addEventListener("focusin", e => { if (e.target.matches && e.target.matches(".help")) showHelp(e.target); });
    document.addEventListener("focusout", e => { if (e.target.matches && e.target.matches(".help")) tip.hide(); });
    document.addEventListener("click", e => { const b = e.target.closest(".help"); if (b) showHelp(b); });
    document.addEventListener("keydown", e => { if (e.key === "Escape") tip.hide(); });

    const dlg = document.getElementById("settings");
    document.getElementById("open-settings").addEventListener("click", () => openSettings());
    document.getElementById("settings-close").addEventListener("click", closeSettings);
    dlg.addEventListener("click", e => { if (e.target === dlg) closeSettings(); });
    dlg.addEventListener("close", () => document.getElementById("open-settings").focus());

    document.getElementById("gh-form").addEventListener("submit", e => {
      e.preventDefault();
      const value = document.getElementById("gh-token").value.trim();
      if (!value) return fieldError("gh-error", "Paste a token first.");
      const remember = document.getElementById("gh-remember").checked;
      store.remove(KEYS.token);
      try { (remember ? localStorage : sessionStorage).setItem(KEYS.token, value); } catch (err) {}
      state.token = value;
      document.getElementById("gh-token").value = "";
      fieldError("gh-error", null);
      closeSettings();
      load();
    });
    document.getElementById("gh-remove").addEventListener("click", () => {
      store.remove(KEYS.token);
      state.token = "";
      if (state.data) { state.data.traffic = null; state.data.stars = null; state.data.trafficError = null; }
      paintConnections();
      render();
      load();
    });

    document.getElementById("um-form").addEventListener("submit", e => {
      e.preventDefault();
      const prev = store.get(localStorage, KEYS.umami, null);
      const shareUrl = document.getElementById("ws-share").value.trim();
      const id = document.getElementById("ws-id").value.trim();
      const key = document.getElementById("ws-key").value.trim() || (prev && prev.key) || "";
      if (shareUrl) {
        const parsed = parseShareUrl(shareUrl);
        if (!parsed) return fieldError("ws-error", "That doesn't look like an Umami share link. It contains /share/ followed by a code.");
        store.set(localStorage, KEYS.umami, { url: shareUrl, ...parsed });
      } else {
        if (!/^[0-9a-f-]{36}$/i.test(id)) return fieldError("ws-error", "Paste the share link, or a Website ID and API key.");
        if (!key) return fieldError("ws-error", "Paste the API key.");
        store.set(localStorage, KEYS.umami, { id, key });
      }
      state.ws.share = null;
      state.ws.data = null;
      state.ws.error = null;
      document.getElementById("ws-key").value = "";
      fieldError("ws-error", null);
      closeSettings();
      loadSite();
    });
    document.getElementById("ws-disconnect").addEventListener("click", () => {
      store.remove(KEYS.umami);
      state.ws.data = null;
      state.ws.share = null;
      state.ws.error = null;
      document.getElementById("ws-share").value = "";
      loadSite();
    });

    document.getElementById("refresh").addEventListener("click", load);
    bindSeg("dl-mode", "dlMode", String, render);
    bindSeg("ws-range", "wsRange", Number, () => { state.ws.range = state.wsRange; loadSite(); });
    bindSeg("tr-range", "range", Number, render);
    bindSeg("tr-kind", "kind", String, render);

    document.querySelectorAll(".card").forEach(c => {
      const btn = c.querySelector(".tbtn");
      if (!btn) return;
      btn.addEventListener("click", () => {
        const on = btn.getAttribute("aria-pressed") !== "true";
        btn.setAttribute("aria-pressed", String(on));
        btn.textContent = on ? "Chart" : "Table";
        c.querySelector("[data-chart]").hidden = on;
        c.querySelector("[data-table]").hidden = !on;
      });
    });

    let lastWidth = 0, pending = 0;
    new ResizeObserver(entries => {
      const w = Math.round(entries[0].contentRect.width);
      if (w === lastWidth) return;
      lastWidth = w;
      cancelAnimationFrame(pending);
      pending = requestAnimationFrame(render);
    }).observe(document.getElementById("main"));

    window.addEventListener("scroll", () => tip.hide(), { passive: true });
    setInterval(renderMeta, 30000);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible" && state.fetchedAt && Date.now() - state.fetchedAt > STALE_MS) load();
    });

    selectTab(location.hash.slice(1) || "overview", { push: false });
    skeleton();
    paintConnections();
    renderOverview();
    load();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
