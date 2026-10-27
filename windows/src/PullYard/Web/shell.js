(function () {
  "use strict";
  var host = window.chrome && window.chrome.webview;
  var pendingScroll = null;

  function send(msg) {
    if (host) host.postMessage(msg);
  }

  window.post = function (type, id) {
    send({ type: type, id: String(id) });
  };

  function fileOf(el) {
    var s = el && el.closest ? el.closest("section.file") : null;
    return s ? s.getAttribute("data-path") : null;
  }

  window.postFile = function (el, type) {
    var p = fileOf(el);
    if (p !== null) send({ type: type, id: p });
  };

  window.toggleFile = function (el) {
    var s = el.closest("section.file");
    if (!s) return;
    var collapsed = !s.classList.contains("collapsed");
    s.classList.toggle("collapsed", collapsed);
    var chev = s.querySelector(".chev");
    if (chev) chev.textContent = collapsed ? "▸" : "▾";
    var body = s.querySelector(".fbody");
    if (body) body.style.display = collapsed ? "none" : "";
    send({ type: collapsed ? "collapse" : "expand", id: s.getAttribute("data-path") });
  };

  var handlerRx = /^\s*(post|postFile|toggleFile)\((.*)\)\s*;?\s*$/;
  var argRx = /'((?:[^'\\]|\\.)*)'/g;

  function decodeArg(s) {
    var t = document.createElement("textarea");
    t.innerHTML = s;
    return t.value;
  }

  function runInline(el, attr) {
    var code = el.getAttribute(attr);
    if (!code) return false;
    var m = handlerRx.exec(code);
    if (!m) return false;
    var args = [];
    var a;
    argRx.lastIndex = 0;
    while ((a = argRx.exec(m[2])) !== null) args.push(decodeArg(a[1]));
    if (m[1] === "post") window.post(args[0], args[1] || "");
    else if (m[1] === "postFile") window.postFile(el, args[0]);
    else if (m[1] === "toggleFile") window.toggleFile(el);
    return true;
  }

  document.addEventListener("click", function (e) {
    var t = e.target;
    if (!(t instanceof Element)) return;
    var gutter = t.closest("td[data-c]");
    if (gutter) {
      send({ type: "comment", id: gutter.getAttribute("data-c") });
      return;
    }
    var inline = t.closest("[onclick]");
    if (inline && runInline(inline, "onclick")) {
      e.preventDefault();
      return;
    }
    var a = t.closest("a[href]");
    if (a) {
      var href = a.getAttribute("href");
      if (!href || href.charAt(0) === "#") {
        if (href && href.length > 1) {
          var target = document.getElementById(href.slice(1)) || document.querySelector("[name='" + href.slice(1).replace(/'/g, "") + "']");
          if (target) target.scrollIntoView({ block: "start" });
        }
        e.preventDefault();
        return;
      }
      e.preventDefault();
      var url;
      try {
        url = new URL(href, "https://github.com/").href;
      } catch (err) {
        return;
      }
      send({ type: "link", id: url });
    }
  }, true);

  document.addEventListener("change", function (e) {
    var t = e.target;
    if (t instanceof Element && t.hasAttribute("onchange")) runInline(t, "onchange");
  }, true);

  document.addEventListener("keydown", function (e) {
    if ((e.ctrlKey || e.metaKey) && (e.key === "r" || e.key === "R")) {
      e.preventDefault();
      send({ type: "refresh", id: "" });
    }
    if (e.key === "F5") {
      e.preventDefault();
      send({ type: "refresh", id: "" });
    }
    var altGraph = e.getModifierState && e.getModifierState("AltGraph");
    var typing = e.target instanceof Element && e.target.closest("input, textarea, select, [contenteditable]");
    if (e.ctrlKey && e.shiftKey && !e.altKey && !altGraph && e.code === "KeyC") {
      e.preventDefault();
      send({ type: "key", id: "shortLink" });
    }
    if (e.ctrlKey && e.altKey && !e.shiftKey && !altGraph && !typing && e.code === "KeyB") {
      e.preventDefault();
      send({ type: "key", id: "blame" });
    }
    if (e.ctrlKey && !e.altKey && !e.metaKey && !altGraph && e.code === "KeyK") {
      e.preventDefault();
      send({ type: "app", id: e.shiftKey ? "quickopen" : "palette" });
    }
    if (!e.ctrlKey && !e.altKey && !e.metaKey && !altGraph && !typing && document.body.classList.contains("review") && reviewKeys.indexOf(e.key) >= 0) {
      e.preventDefault();
      send({ type: "review", id: e.key });
    }
  });

  var reviewKeys = ["n", "p", "[", "]", "v", "w", "s"];

  function headerHeight() {
    var h = document.querySelector("section.file .fh");
    return h ? h.getBoundingClientRect().height : 0;
  }

  function currentFile() {
    var sections = document.querySelectorAll("section.file");
    var current = null;
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].getBoundingClientRect().top > 4) break;
      current = sections[i];
    }
    return { sections: sections, current: current || sections[0] || null };
  }

  function stepFile(delta) {
    var info = currentFile();
    if (!info.current) return;
    var index = Array.prototype.indexOf.call(info.sections, info.current);
    var next = Math.min(Math.max(index + delta, 0), info.sections.length - 1);
    var target = info.sections[next];
    if (target === info.current && info.current.getBoundingClientRect().top >= -1) return;
    send({ type: "reveal", id: target.getAttribute("data-path") });
  }

  function stepHunk(delta) {
    var hunks = document.querySelectorAll("section.file tr.hk");
    var top = headerHeight();
    var target = null;
    for (var i = 0; i < hunks.length; i++) {
      var y = hunks[i].getBoundingClientRect().top;
      if (delta > 0 && y > top + 2) {
        target = hunks[i];
        break;
      }
      if (delta < 0 && y < top - 2) target = hunks[i];
    }
    if (target) window.scrollBy(0, target.getBoundingClientRect().top - top);
  }

  function review(key) {
    if (key === "n") stepFile(1);
    else if (key === "p") stepFile(-1);
    else if (key === "]") stepHunk(1);
    else if (key === "[") stepHunk(-1);
    else if (key === "v") {
      var info = currentFile();
      if (info.current) send({ type: "viewed", id: info.current.getAttribute("data-path") });
    }
  }

  var shift = 0;
  var shiftMax = 0;

  function setShift(value) {
    shift = Math.max(0, Math.min(value, shiftMax));
    var root = document.querySelector(".diff.nw");
    if (root) root.style.setProperty("--sx", shift.toFixed(2) + "ch");
  }

  function syncBar() {
    var bar = document.getElementById("hbar");
    var root = document.querySelector(".diff.nw");
    if (!bar || !root) return;
    var widest = 0;
    var tables = root.querySelectorAll("table.dt.nw");
    for (var i = 0; i < tables.length; i++) widest = Math.max(widest, +tables[i].getAttribute("data-maxch") || 0);
    var code = root.querySelector("table.dt.nw td.c > .w");
    var visible = 0;
    if (code) {
      var probe = document.createElement("span");
      probe.textContent = "0000000000";
      probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
      code.appendChild(probe);
      var ch = probe.offsetWidth / 10;
      code.removeChild(probe);
      if (ch > 0) visible = Math.max(1, (code.parentElement.clientWidth - 8) / ch);
    }
    shiftMax = visible > 0 ? Math.max(0, widest - visible) : 0;
    if (shiftMax < 0.5) {
      bar.classList.remove("on");
      setShift(0);
      return;
    }
    bar.classList.add("on");
    bar.firstElementChild.style.width = Math.round(bar.clientWidth * widest / visible) + "px";
    setShift(shift);
    var range = bar.scrollWidth - bar.clientWidth;
    if (range > 0) bar.scrollLeft = shift / shiftMax * range;
  }

  document.addEventListener("scroll", function (e) {
    var bar = e.target;
    if (!(bar instanceof Element) || bar.id !== "hbar") return;
    var range = bar.scrollWidth - bar.clientWidth;
    setShift(range > 0 ? bar.scrollLeft / range * shiftMax : 0);
  }, true);

  document.addEventListener("wheel", function (e) {
    var bar = document.getElementById("hbar");
    if (!bar || !bar.classList.contains("on") || !(e.target instanceof Element) || !e.target.closest("table.dt.nw")) return;
    var dx = e.deltaX || (e.shiftKey ? e.deltaY : 0);
    if (!dx) return;
    e.preventDefault();
    bar.scrollLeft += dx;
  }, { passive: false });

  window.addEventListener("resize", syncBar);

  function scrollToFile(path) {
    var sections = document.querySelectorAll("section.file");
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].getAttribute("data-path") === path) {
        sections[i].scrollIntoView({ block: "start" });
        return true;
      }
    }
    return false;
  }

  function render(msg) {
    var root = document.getElementById("root");
    var y = window.scrollY;
    document.getElementById("dyn").textContent = msg.css || "";
    document.body.className = msg.bodyClass || "";
    root.innerHTML = msg.html || "";
    var collapsed = root.querySelectorAll("section.file.collapsed .fbody");
    for (var i = 0; i < collapsed.length; i++) collapsed[i].style.display = "none";
    if (msg.scroll === "bottom") {
      window.scrollTo(0, document.body.scrollHeight);
    } else if (msg.scroll === "top") {
      window.scrollTo(0, 0);
    } else if (msg.scroll && msg.scroll.indexOf("file:") === 0) {
      scrollToFile(msg.scroll.slice(5));
    } else {
      window.scrollTo(0, y);
    }
    syncBar();
  }

  function onMessage(e) {
    var msg = e.data;
    if (typeof msg === "string") {
      try {
        msg = JSON.parse(msg);
      } catch (err) {
        return;
      }
    }
    if (!msg || !msg.op) return;
    switch (msg.op) {
      case "render":
        render(msg);
        break;
      case "fileBody": {
        var sections = document.querySelectorAll("section.file");
        for (var i = 0; i < sections.length; i++) {
          if (sections[i].getAttribute("data-path") === msg.path) {
            var body = sections[i].querySelector(".fbody");
            if (body) {
              body.innerHTML = msg.html;
              body.style.display = "";
            }
          }
        }
        syncBar();
        break;
      }
      case "review":
        review(msg.key);
        break;
      case "scrollToFile":
        scrollToFile(msg.path);
        break;
      case "scrollBottom":
        window.scrollTo(0, document.body.scrollHeight);
        break;
      case "find":
        if (window.find) window.find(msg.text || "");
        break;
    }
  }

  document.addEventListener("keydown", function (e) {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    var id = e.key === "=" || e.key === "+" ? "in" : e.key === "-" || e.key === "_" ? "out" : e.key === "0" ? "reset" : null;
    if (!id) return;
    e.preventDefault();
    send({ type: "zoom", id: id });
  }, true);

  if (host) host.addEventListener("message", onMessage);
  document.addEventListener("DOMContentLoaded", function () {
    send({ type: "ready", id: "" });
  });
})();
