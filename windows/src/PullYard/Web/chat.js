(function () {
  "use strict";
  var host = window.chrome && window.chrome.webview;
  var items = [];
  var byId = {};
  var nodes = {};
  var versions = {};
  var openState = {};
  var expandedUser = {};
  var answers = {};
  var feedback = {};
  var strings = {};
  var meta = { busy: false, running: false, sleeping: false, pendingCount: 0, folder: "" };
  var stick = true;
  var jumping = false;
  var jumpTimer = null;
  var awayCount = null;
  var todoOpen = false;
  var tickTimer = null;

  var ICONS = {
    command: '<path d="M3 4.5l3.5 3.5L3 11.5M8.5 12h4.5"/>',
    read: '<path d="M4 1.8h5l3 3v9.4H4z"/><path d="M9 1.8v3h3"/>',
    edit: '<path d="M10.8 2.2l3 3-8.3 8.3H2.5v-3z"/>',
    search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2l3.8 3.8"/>',
    web: '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2.4 2.2 2.4 9.8 0 12M8 2c-2.4 2.2-2.4 9.8 0 12"/>',
    agent: '<circle cx="6" cy="5.2" r="2.4"/><path d="M1.6 14c0-2.9 2-4.4 4.4-4.4s4.4 1.5 4.4 4.4"/><circle cx="11.6" cy="5.6" r="1.9"/><path d="M11.4 9.6c1.9 0 3.2 1.2 3.2 3.4"/>',
    other: '<path d="M9.8 2.3a3.3 3.3 0 0 0-3.6 4.3L2.4 10.4a1.4 1.4 0 0 0 2 2l3.8-3.8a3.3 3.3 0 0 0 4.3-3.6l-2 2-1.9-.5-.5-1.9z"/>',
    copy: '<rect x="5.2" y="5.2" width="8.3" height="8.3" rx="1.6"/><path d="M10.8 5.2V3.6c0-.9-.7-1.6-1.6-1.6H3.6C2.7 2 2 2.7 2 3.6v5.6c0 .9.7 1.6 1.6 1.6h1.6"/>',
    check: '<path d="M3 8.5l3.2 3.2L13 4.8"/>',
    rewind: '<path d="M5.5 3.5L2.5 6.5l3 3"/><path d="M2.5 6.5h7a4 4 0 0 1 0 8h-3"/>',
    down: '<path d="M8 3v10M3.5 8.5L8 13l4.5-4.5"/>',
    chev: '<path d="M6 3.5L10.5 8 6 12.5"/>',
    pr: '<circle cx="4" cy="3.5" r="1.6"/><circle cx="4" cy="12.5" r="1.6"/><circle cx="12" cy="12.5" r="1.6"/><path d="M4 5.1v5.8M12 10.9V6.5c0-1.1-.9-2-2-2H7.5M9 3l-1.5 1.5L9 6"/>',
    clock: '<circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.4 1.6"/>',
    branch: '<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="5" r="1.6"/><path d="M4.5 5.1v5.8M11.5 6.6c0 2.6-3.5 2.4-6.2 4.5"/>',
    person: '<circle cx="8" cy="5.5" r="2.8"/><path d="M2.8 14c.4-3 2.5-4.6 5.2-4.6s4.8 1.6 5.2 4.6"/>',
    review: '<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>',
    chat: '<path d="M2.5 3h11v7.5H7l-3 2.5v-2.5H2.5z"/>',
    map: '<path d="M1.8 3.5l4-1.5 4.4 1.5 4-1.5v10.5l-4 1.5-4.4-1.5-4 1.5z"/><path d="M5.8 2v10.5M10.2 3.5V14"/>',
    bug: '<rect x="4.5" y="5" width="7" height="8.5" rx="3.5"/><path d="M6 5V4a2 2 0 0 1 4 0v1M1.8 9h2.7M11.5 9h2.7M2.5 5.5l2 1.3M13.5 5.5l-2 1.3M2.5 13l2-1.5M13.5 13l-2-1.5"/>',
    test: '<path d="M8 1.6l1.7 1.3 2.1-.1.6 2 1.8 1.1-.7 2 .7 2-1.8 1.1-.6 2-2.1-.1L8 14.4 6.3 13.1l-2.1.1-.6-2-1.8-1.1.7-2-.7-2 1.8-1.1.6-2 2.1.1z"/><path d="M5.6 8.1l1.7 1.7 3.2-3.3"/>'
  };

  function icon(name, cls) {
    return '<svg class="ic' + (cls ? " " + cls : "") + '" viewBox="0 0 16 16" aria-hidden="true">' + (ICONS[name] || ICONS.other) + "</svg>";
  }

  function t(key, fallback, arg) {
    var s = strings[key] || fallback;
    return arg == null ? s : s.replace("{0}", arg);
  }

  function send(msg) {
    if (host) host.postMessage(msg);
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  if (window.marked) {
    marked.use({
      gfm: true,
      breaks: false,
      renderer: {
        html: function (token) {
          return esc(typeof token === "object" ? (token.text || token.raw || "") : token);
        }
      }
    });
  }

  function md(text) {
    if (!window.marked) return "<p>" + esc(text) + "</p>";
    try {
      return marked.parse(text || "");
    } catch (e) {
      return "<p>" + esc(text) + "</p>";
    }
  }

  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }

  function button(label, cls, onClick) {
    var b = el("button", "b " + (cls || ""));
    b.textContent = label;
    b.addEventListener("click", function (e) {
      e.stopPropagation();
      onClick(e);
    });
    return b;
  }

  function copyText(text) {
    if (host) send({ type: "copy", text: text });
    else if (navigator.clipboard) navigator.clipboard.writeText(text).catch(function () {});
  }

  function atBottom() {
    return window.innerHeight + window.scrollY >= document.body.scrollHeight - 40;
  }

  function scrollDown() {
    window.scrollTo(0, document.body.scrollHeight);
    stick = true;
    awayCount = null;
  }

  function anchor() {
    var kids = document.getElementById("list").children;
    for (var i = 0; i < kids.length; i++) {
      var r = kids[i].getBoundingClientRect();
      if (r.bottom > 0) return { id: kids[i].getAttribute("data-id"), top: r.top };
    }
    return null;
  }

  function restore(a) {
    if (!a) return;
    var n = nodes[a.id];
    if (!n || !n.parentNode) return;
    var delta = n.getBoundingClientRect().top - a.top;
    if (delta) window.scrollBy(0, delta);
  }

  function preserving(change) {
    var follow = stick;
    var a = follow ? null : anchor();
    change();
    if (follow) scrollDown();
    else restore(a);
    updateJump();
  }

  function repin() {
    if (stick && window.innerHeight > 0) window.scrollTo(0, document.body.scrollHeight);
  }

  window.addEventListener("scroll", function () {
    if (window.innerHeight <= 0) return;
    if (jumping) {
      if (atBottom()) finishJump();
      return;
    }
    var was = stick;
    stick = atBottom();
    if (was && !stick) awayCount = items.length;
    if (stick) awayCount = null;
    updateJump();
  }, { passive: true });

  window.addEventListener("resize", repin);

  document.addEventListener("load", function (e) {
    if (e.target instanceof HTMLImageElement) repin();
  }, true);

  function finishJump() {
    jumping = false;
    if (jumpTimer) clearTimeout(jumpTimer);
    jumpTimer = null;
    stick = true;
    awayCount = null;
    updateJump();
  }

  function jumpToLatest() {
    stick = true;
    awayCount = null;
    jumping = true;
    updateJump();
    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({ top: document.body.scrollHeight, behavior: reduced ? "auto" : "smooth" });
    if (jumpTimer) clearTimeout(jumpTimer);
    jumpTimer = setTimeout(function () {
      window.scrollTo(0, document.body.scrollHeight);
      finishJump();
    }, 900);
  }

  function updateJump() {
    var b = document.getElementById("jump");
    if (!b) return;
    var show = !stick && !jumping && items.length > 0;
    var fresh = show && awayCount != null ? Math.max(0, items.length - awayCount) : 0;
    b.classList.toggle("show", show);
    b.classList.toggle("fresh", fresh > 0);
    b.tabIndex = show ? 0 : -1;
    var badge = b.querySelector(".badge");
    var label = fresh > 99 ? "99+" : String(fresh);
    if (badge.textContent !== label) {
      badge.textContent = label;
      badge.classList.remove("pop");
      if (fresh > 0) {
        void badge.offsetWidth;
        badge.classList.add("pop");
      }
    }
    b.title = fresh > 0 ? t("ChatWeb_JumpNew", "{0} new — jump to the latest message", fresh) : t("ChatWeb_JumpLatest", "Jump to the latest message");
  }

  function relative(path) {
    var f = (meta.folder || "").replace(/[\\/]+$/, "");
    if (f && (path.indexOf(f + "\\") === 0 || path.indexOf(f + "/") === 0)) return path.slice(f.length + 1);
    return path;
  }

  function diffLines(item) {
    var out = [];
    var patch = item.structured && item.structured.structuredPatch;
    if (patch && patch.length) {
      patch.forEach(function (h) {
        var o = h.oldStart || 1, n = h.newStart || 1;
        (h.lines || []).forEach(function (l) {
          var c = l.charAt(0), body = l.slice(1);
          if (c === "+") { out.push({ k: "a", t: body, n: n }); n++; }
          else if (c === "-") { out.push({ k: "d", t: body, o: o }); o++; }
          else { out.push({ k: "", t: body, o: o, n: n }); o++; n++; }
        });
      });
      return out;
    }
    var input = item.input || {};
    if (item.name === "Write") {
      String(input.content || "").split("\n").forEach(function (l, i) { out.push({ k: "a", t: l, n: i + 1 }); });
      return out;
    }
    var edits = item.name === "MultiEdit" ? (input.edits || []) : [input];
    edits.forEach(function (e) {
      String(e.old_string || "").split("\n").forEach(function (l) { out.push({ k: "d", t: l }); });
      String(e.new_string || "").split("\n").forEach(function (l) { out.push({ k: "a", t: l }); });
    });
    return out;
  }

  function diffStat(item) {
    var patch = item.structured && item.structured.structuredPatch;
    if (patch && patch.length) {
      var a = 0, d = 0;
      patch.forEach(function (h) { (h.lines || []).forEach(function (l) { if (l.charAt(0) === "+") a++; else if (l.charAt(0) === "-") d++; }); });
      return { a: a, d: d };
    }
    if (item.name === "Write" && item.input && typeof item.input.content === "string") return { a: item.input.content.split("\n").length, d: 0 };
    return null;
  }

  function renderDiff(item, container) {
    var lines = diffLines(item);
    var box = el("div", "diff");
    var showAll = !!openState["all:" + item.id];
    var shown = showAll ? lines : lines.slice(0, 60);
    var html = "";
    shown.forEach(function (l) {
      var g = l.k === "d" ? (l.o || "") : (l.n || "");
      var sign = l.k === "a" ? "+" : l.k === "d" ? "-" : " ";
      html += '<div class="' + l.k + '"><span class="g">' + g + "</span>" + esc(sign + l.t) + "</div>";
    });
    box.innerHTML = html;
    container.appendChild(box);
    if (lines.length > 60 && !showAll) {
      container.appendChild(button("Show " + (lines.length - 60) + " more lines", "small", function () {
        openState["all:" + item.id] = true;
        update(item);
      }));
    }
  }

  function output(container, text, title) {
    if (!text || !String(text).trim()) return;
    if (title) container.appendChild(el("div", "lbl", esc(title)));
    var pre = el("pre", "out");
    pre.textContent = String(text).slice(0, 20000);
    container.appendChild(pre);
  }

  function renderDetails(item, det) {
    var input = item.input || {};
    switch (item.name) {
      case "Edit":
      case "MultiEdit":
      case "Write":
        if (input.file_path) {
          var row = el("div", "pathrow");
          row.appendChild(el("span", "", esc(relative(input.file_path))));
          row.appendChild(button("Open", "small", function () { send({ type: "open", path: input.file_path }); }));
          det.appendChild(row);
        }
        renderDiff(item, det);
        break;
      case "Bash":
        if (input.command) {
          var c = el("div", "cmd");
          c.textContent = "$ " + input.command;
          det.appendChild(c);
        }
        var s = item.structured || {};
        var out = (s.stdout || "") + (s.stderr ? "\n" + s.stderr : "");
        output(det, out || item.result);
        break;
      case "TodoWrite":
        (input.todos || []).forEach(function (t) {
          var st = t.status || "pending";
          var r = el("div", "todo " + st);
          r.appendChild(el("span", "i", st === "completed" ? "✔" : st === "in_progress" ? "◉" : "○"));
          var tt = el("span", "t");
          tt.textContent = t.content || t.subject || "";
          r.appendChild(tt);
          det.appendChild(r);
        });
        break;
      case "ExitPlanMode":
        det.appendChild(el("div", "md", md(input.plan || "")));
        break;
      case "AskUserQuestion":
        (input.questions || []).forEach(function (q) {
          var qq = el("div", "");
          qq.style.fontWeight = "600";
          qq.textContent = q.question || "";
          det.appendChild(qq);
        });
        if (item.result) output(det, item.result);
        break;
      case "Read":
        output(det, (item.structured && item.structured.fileContent) || item.result);
        break;
      default:
        if (input && Object.keys(input).length) output(det, JSON.stringify(input, null, 2), "Input");
        output(det, item.result, "Result");
    }
  }

  function permissionCard(item) {
    var p = item.permission;
    var card = el("div", "perm");
    var key = p.id;
    if (p.toolName === "AskUserQuestion") {
      var qs = (p.input && p.input.questions) || [];
      answers[key] = answers[key] || {};
      qs.forEach(function (q) {
        var text = q.question || "";
        var wrap = el("div", "");
        var title = el("div", "");
        title.style.fontWeight = "600";
        title.textContent = text;
        wrap.appendChild(title);
        (q.options || []).forEach(function (o) {
          var label = o.label || "";
          var opt = el("div", "opt" + (answers[key][text] === label ? " sel" : ""));
          opt.appendChild(el("span", "dot"));
          var body = el("div", "");
          var l = el("div", "");
          l.textContent = label;
          body.appendChild(l);
          if (o.description) {
            var d = el("div", "od");
            d.textContent = o.description;
            body.appendChild(d);
          }
          opt.appendChild(body);
          opt.addEventListener("click", function () {
            answers[key][text] = label;
            update(item);
          });
          wrap.appendChild(opt);
        });
        var other = el("input");
        other.type = "text";
        other.placeholder = "Other…";
        var isOption = (q.options || []).some(function (o) { return o.label === answers[key][text]; });
        other.value = isOption ? "" : (answers[key][text] || "");
        other.addEventListener("input", function () { answers[key][text] = other.value; });
        other.addEventListener("change", function () { update(item); });
        wrap.appendChild(other);
        card.appendChild(wrap);
      });
      var row = el("div", "row");
      var submit = button("Submit", "primary", function () {
        send({ type: "perm", id: key, action: "answer", answers: answers[key] });
      });
      submit.disabled = Object.keys(answers[key]).filter(function (k) { return answers[key][k]; }).length < qs.length;
      row.appendChild(submit);
      row.appendChild(button("Skip", "", function () {
        send({ type: "perm", id: key, action: "deny", message: "The user skipped the question" });
      }));
      card.appendChild(row);
      return card;
    }
    if (p.toolName === "ExitPlanMode") {
      card.appendChild(el("div", "", "<b>Claude has a plan. Start implementing?</b>"));
      var r1 = el("div", "row");
      r1.appendChild(button("Yes, auto-accept edits", "primary", function () { send({ type: "perm", id: key, action: "allow", mode: "acceptEdits" }); }));
      r1.appendChild(button("Yes, ask before edits", "", function () { send({ type: "perm", id: key, action: "allow", mode: "default" }); }));
      card.appendChild(r1);
      card.appendChild(denyRow(key, "What to change in the plan…"));
      return card;
    }
    card.appendChild(el("div", "q", esc(p.question)));
    if (p.description) card.appendChild(el("div", "desc", esc(p.description)));
    if (p.blockedPath) card.appendChild(el("div", "pathrow", esc(p.blockedPath)));
    var allowRow = el("div", "row");
    allowRow.appendChild(button("Allow", "primary", function () { send({ type: "perm", id: key, action: "allow" }); }));
    card.appendChild(allowRow);
    (p.suggestions || []).forEach(function (label, i) {
      var a = el("button", "always");
      a.textContent = "Allow, and don't ask again for " + label;
      a.addEventListener("click", function (e) {
        e.stopPropagation();
        send({ type: "perm", id: key, action: "always", index: i });
      });
      card.appendChild(a);
    });
    card.appendChild(denyRow(key, "No — tell Claude what to do instead…"));
    return card;
  }

  function denyRow(key, placeholder) {
    var row = el("div", "row");
    var input = el("input");
    input.type = "text";
    input.placeholder = placeholder;
    input.value = feedback[key] || "";
    input.addEventListener("input", function () { feedback[key] = input.value; });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") send({ type: "perm", id: key, action: "deny", message: input.value });
    });
    row.appendChild(input);
    row.appendChild(button("Deny", "", function () { send({ type: "perm", id: key, action: "deny", message: input.value }); }));
    return row;
  }

  function defaultOpen(item) {
    if (item.permission && !item.permission.resolved) return true;
    return ["Edit", "MultiEdit", "Write", "ExitPlanMode", "TodoWrite"].indexOf(item.name) >= 0;
  }

  function statusIcon(item) {
    if (item.status === "running") {
      if (item.permission && !item.permission.resolved) return '<span class="st wait">✋</span>';
      return '<span class="st"><span class="spin"></span></span>';
    }
    if (item.status === "done") return '<span class="st done">✔</span>';
    if (item.status === "error") return '<span class="st error">✖</span>';
    return '<span class="st denied">⊘</span>';
  }

  function statHtml(item) {
    var stat = diffStat(item);
    return stat ? '<span class="stat"><span class="plus">+' + stat.a + '</span> <span class="minus">−' + stat.d + "</span></span>" : "";
  }

  function touch(id) {
    versions[id] = (versions[id] || 0) + 1;
  }

  function update(item) {
    touch(item.id);
    var a = anchor();
    render();
    restore(a);
  }

  function actions(list) {
    var row = el("div", "acts");
    list.forEach(function (a) {
      var b = el("button", "act", icon(a.icon) + (a.icon === "copy" ? icon("check", "ok") : ""));
      b.title = a.title;
      b.setAttribute("aria-label", a.title);
      b.addEventListener("click", function (e) {
        e.stopPropagation();
        a.run();
        if (a.icon !== "copy") return;
        b.classList.add("done");
        setTimeout(function () { b.classList.remove("done"); }, 1200);
      });
      row.appendChild(b);
    });
    return row;
  }

  function userNode(item) {
    var wrap = el("div", "msg mine");
    var long = (item.text || "").split("\n").length > 12;
    var node = el("div", "card user" + (long && !expandedUser[item.id] ? " clamped" : ""));
    if (item.images && item.images.length) {
      var imgs = el("div", "imgs");
      item.images.forEach(function (src) {
        var i = el("img");
        i.src = src;
        imgs.appendChild(i);
      });
      node.appendChild(imgs);
    }
    if (item.text) {
      var tx = el("div", "txt");
      tx.textContent = item.text;
      node.appendChild(tx);
      if (long) {
        node.appendChild(button(expandedUser[item.id] ? "Collapse" : "Show all", "more", function () {
          expandedUser[item.id] = !expandedUser[item.id];
          update(item);
        }));
      }
    }
    wrap.appendChild(node);
    if (item.text) {
      wrap.appendChild(actions([
        { icon: "copy", title: t("ChatWeb_Copy", "Copy"), run: function () { copyText(item.text); } },
        { icon: "rewind", title: t("ChatWeb_EditFromHere", "Edit from here — continues in a new branch of this session"), run: function () { send({ type: "rewind", id: item.id }); } }
      ]));
    }
    return wrap;
  }

  function textNode(item) {
    var wrap = el("div", "msg");
    wrap.appendChild(el("div", "md", md(item.text)));
    if (item.finalized) {
      wrap.appendChild(actions([{ icon: "copy", title: t("ChatWeb_Copy", "Copy"), run: function () { copyText(item.text); } }]));
    }
    return wrap;
  }

  function toolCard(item) {
    var open = openState[item.id] != null ? openState[item.id] : defaultOpen(item);
    var node = el("div", "card tool " + item.status + (open ? " open" : ""));
    var head = el("div", "th");
    head.innerHTML = statusIcon(item) + "<span>" + esc(item.icon) + '</span><span class="name">' + esc(item.title) + '</span><span class="sum">' + esc(item.summary) + "</span>" +
      statHtml(item) + icon("chev", "chev");
    head.addEventListener("click", function () {
      openState[item.id] = !(openState[item.id] != null ? openState[item.id] : defaultOpen(item));
      update(item);
    });
    node.appendChild(head);
    var det = el("div", "det");
    if (open) renderDetails(item, det);
    node.appendChild(det);
    if (item.permission && !item.permission.resolved) node.appendChild(permissionCard(item));
    return node;
  }

  function build(item) {
    switch (item.kind) {
      case "user":
        return userNode(item);
      case "text":
        return textNode(item);
      case "thinking": {
        var node = el("details", "thinking");
        if (openState[item.id]) node.open = true;
        node.appendChild(el("summary", "", "▸ 🧠 " + esc(t("ChatWeb_Thinking", "Thinking"))));
        var body = el("div", "body");
        body.textContent = item.text || "";
        node.appendChild(body);
        node.addEventListener("toggle", function () { openState[item.id] = node.open; });
        return node;
      }
      case "notice": {
        var n = el("div", "notice" + (item.error ? " err" : ""));
        n.textContent = item.text;
        return n;
      }
      case "tool":
        return toolCard(item);
      default:
        return el("div", "");
    }
  }

  var VERBS = { command: "ran", read: "read", edit: "edited", search: "searched", web: "fetched", agent: "ran", other: "used" };
  var NOUNS = {
    command: ["command", "commands"], read: ["file", "files"], edit: ["file", "files"], search: ["pattern", "patterns"],
    web: ["page", "pages"], agent: ["agent", "agents"], other: ["tool", "tools"]
  };
  var KINDS = ["command", "read", "edit", "search", "web", "agent", "other"];

  function groupLabel(calls) {
    var counts = {};
    calls.forEach(function (c) { var k = c.group || "other"; counts[k] = (counts[k] || 0) + 1; });
    var text = KINDS.filter(function (k) { return counts[k]; }).map(function (k) {
      return VERBS[k] + " " + counts[k] + " " + NOUNS[k][counts[k] === 1 ? 0 : 1];
    }).join(", ");
    return text.charAt(0).toUpperCase() + text.slice(1);
  }

  function kindIcons(calls) {
    var seen = [];
    calls.forEach(function (c) { var k = c.group || "other"; if (seen.indexOf(k) < 0) seen.push(k); });
    return '<span class="kinds">' + seen.slice(0, 4).map(function (k) { return icon(k, "k-" + k); }).join("") + "</span>";
  }

  function stepRow(item) {
    var open = openState[item.id] === true || (item.permission && !item.permission.resolved);
    var row = el("div", "step" + (open ? " open" : "") + (item.status === "running" ? " live" : ""));
    var head = el("div", "sh");
    var glyph = item.status === "running" ? '<span class="st"><span class="spin"></span></span>' :
      item.status === "error" ? '<span class="st error">✖</span>' : item.status === "denied" ? '<span class="st denied">⊘</span>' : "";
    head.innerHTML = glyph + icon(item.group || "other", "k-" + (item.group || "other")) + '<span class="stitle">' + esc(item.step || item.title) + "</span>" + statHtml(item) + icon("chev", "chev");
    head.addEventListener("click", function (e) {
      e.stopPropagation();
      if (openState[item.id] === true) delete openState[item.id];
      else openState[item.id] = true;
      update(item);
    });
    row.appendChild(head);
    if (open) {
      var det = el("div", "det");
      renderDetails(item, det);
      row.appendChild(det);
    }
    return row;
  }

  function thinkingStep(item) {
    var key = "step:" + item.id;
    var open = !!openState[key];
    var row = el("div", "step think" + (open ? " open" : ""));
    var head = el("div", "sh", '<span class="stitle">' + esc(t("ChatWeb_Thinking", "Thinking")) + "</span>" + icon("chev", "chev"));
    head.addEventListener("click", function (e) {
      e.stopPropagation();
      openState[key] = !open;
      update(item);
    });
    row.appendChild(head);
    if (open) {
      var body = el("div", "tbody");
      body.textContent = item.text || "";
      row.appendChild(body);
    }
    return row;
  }

  function groupNode(entry) {
    var calls = entry.steps.filter(function (s) { return s.kind === "tool"; });
    var key = entry.key;
    var open = !!openState[key] || calls.some(function (c) { return openState[c.id] === true; });
    var running = calls.filter(function (c) { return c.status === "running"; });
    var failed = calls.filter(function (c) { return c.status === "error"; }).length;
    var node = el("div", "group" + (open ? " open" : "") + (running.length ? " live" : ""));
    var head = el("div", "gh");
    head.innerHTML = (running.length ? '<span class="st"><span class="spin"></span></span>' : "") + kindIcons(calls) +
      (running.length ? '<span class="glabel run">' + esc(t("ChatWeb_Running", "Running:") + " " + (running[running.length - 1].step || running[running.length - 1].title)) + "</span>"
        : '<span class="glabel">' + esc(groupLabel(calls)) + "</span>") +
      (failed ? '<span class="gfail">· ' + esc(t("ChatWeb_Failed", "{0} failed", failed)) + "</span>" : "") + icon("chev", "chev");
    head.addEventListener("click", function () {
      if (open) {
        delete openState[key];
        calls.forEach(function (c) { delete openState[c.id]; });
      } else {
        openState[key] = true;
      }
      update(calls[0]);
    });
    node.appendChild(head);
    if (open) {
      var list = el("div", "steps");
      entry.steps.forEach(function (s) { list.appendChild(s.kind === "tool" ? stepRow(s) : thinkingStep(s)); });
      node.appendChild(list);
    }
    return node;
  }

  function shown(item) {
    return !((item.kind === "text" || item.kind === "thinking") && !item.text);
  }

  function entries() {
    var out = [];
    var run = [];
    function flush() {
      var calls = run.filter(function (s) { return s.kind === "tool"; });
      if (!calls.length) run.forEach(function (s) { out.push({ key: s.id, item: s }); });
      else if (run.length === 1) out.push({ key: run[0].id, item: run[0] });
      else out.push({ key: "g" + calls[0].id, steps: run });
      run = [];
    }
    items.forEach(function (it) {
      if (!shown(it)) return;
      if (it.kind === "tool" && it.groupable) run.push(it);
      else if (it.kind === "thinking" && run.length) run.push(it);
      else {
        flush();
        out.push({ key: it.id, item: it });
      }
    });
    flush();
    return out;
  }

  function signature(entry) {
    if (entry.item) return entry.item.id + ":" + (versions[entry.item.id] || 0);
    return entry.steps.map(function (s) { return s.id + ":" + (versions[s.id] || 0); }).join("|");
  }

  function render() {
    var container = document.getElementById("list");
    var list = entries();
    var seen = {};
    var ref = container.firstChild;
    list.forEach(function (entry) {
      var sig = signature(entry);
      var node = nodes[entry.key];
      if (!node || node._sig !== sig) {
        var next = entry.item ? build(entry.item) : groupNode(entry);
        next._sig = sig;
        next.setAttribute("data-id", entry.key);
        if (node && node.parentNode) {
          if (node === ref) ref = next;
          node.parentNode.replaceChild(next, node);
        }
        node = next;
        nodes[entry.key] = node;
      }
      seen[entry.key] = true;
      if (node === ref) ref = ref.nextSibling;
      else container.insertBefore(node, ref);
    });
    while (ref) {
      var gone = ref;
      ref = ref.nextSibling;
      container.removeChild(gone);
    }
    Object.keys(nodes).forEach(function (k) { if (!seen[k]) delete nodes[k]; });
  }

  function apply(list) {
    list.forEach(function (item) {
      if (byId[item.id]) {
        var idx = items.indexOf(byId[item.id]);
        if (idx >= 0) items[idx] = item;
      } else {
        items.push(item);
      }
      byId[item.id] = item;
      touch(item.id);
    });
    render();
    renderTail();
    renderDock();
  }

  function upsert(list) {
    preserving(function () { apply(list); });
  }

  function settle() {
    if (stick) scrollDown();
  }

  function reset(list) {
    items = [];
    byId = {};
    nodes = {};
    document.getElementById("list").innerHTML = "";
    apply(list);
    scrollDown();
    updateJump();
    setTimeout(settle, 30);
    setTimeout(settle, 300);
  }

  function welcome() {
    var w = meta.welcome;
    var box = el("div", "welcome");
    if (!w) {
      box.appendChild(el("h3", "", "✨ Claude Code"));
      box.appendChild(el("div", "", esc(t("ChatWeb_WelcomeIntro", "Describe a task. The agent reads the code, proposes changes and asks before acting."))));
      box.appendChild(el("div", "hint", esc(t("ChatWeb_Hint", "/ commands · @ files · Shift+Enter new line · paste a screenshot Ctrl+V"))));
      return box;
    }
    var top = el("div", "wtop");
    top.appendChild(el("div", "wlogo", icon("chat")));
    var titles = el("div", "wtitles");
    titles.appendChild(el("h3", "", esc(w.project || "")));
    var sub = el("div", "wsub");
    if (w.branch) {
      sub.innerHTML = '<span class="wbranch">' + icon("branch") + esc(w.branch) + "</span>" +
        (w.changed ? '<span class="wchanged">· ' + esc(t("ChatWeb_Changed", "{0} changed", w.changed)) + "</span>" : "") +
        (w.ahead ? "<span>· " + esc(t("ChatWeb_Unpushed", "{0} unpushed", w.ahead)) + "</span>" : "");
    } else {
      sub.textContent = w.folder || meta.folder || "";
    }
    titles.appendChild(sub);
    top.appendChild(titles);
    box.appendChild(top);
    box.appendChild(el("div", "wintro", esc(t("ChatWeb_WelcomeIntro", "Describe a task. The agent reads the code, proposes changes and asks before acting."))));
    var grid = el("div", "wgrid");
    (w.suggestions || []).forEach(function (s) {
      var b = el("button", "sug", icon(s.icon) + "<span>" + esc(s.title) + "</span>");
      b.addEventListener("click", function (e) {
        e.stopPropagation();
        send({ type: "send", text: s.prompt });
      });
      grid.appendChild(b);
    });
    box.appendChild(grid);
    if (w.recent && w.recent.length) {
      var rec = el("div", "wrecent");
      rec.appendChild(el("div", "wlabel", esc(t("ChatWeb_Recent", "Recent in this project"))));
      w.recent.forEach(function (r) {
        var row = el("button", "wrow", icon("clock") + '<span class="wt">' + esc(r.title) + '</span><span class="wago">' + esc(r.ago || "") + "</span>");
        row.addEventListener("click", function (e) {
          e.stopPropagation();
          send({ type: "resume", id: r.id });
        });
        rec.appendChild(row);
      });
      box.appendChild(rec);
    }
    box.appendChild(el("div", "hint", esc(t("ChatWeb_Hint", "/ commands · @ files · Shift+Enter new line · paste a screenshot Ctrl+V"))));
    return box;
  }

  function prCard(pr) {
    var card = el("div", "prcard");
    card.appendChild(el("div", "prtile", icon("pr")));
    var text = el("div", "prtext");
    text.appendChild(el("div", "prtitle", esc(t("ChatWeb_PROpen", "Pull request #{0} is open", pr.number))));
    if (pr.repo) text.appendChild(el("div", "prrepo", esc(pr.repo)));
    card.appendChild(text);
    var copy = button(t("ChatWeb_CopyLink", "Copy link"), "small", function () {
      copyText(pr.url);
      copy.textContent = t("ChatWeb_Copied", "Copied");
      setTimeout(function () { copy.textContent = t("ChatWeb_CopyLink", "Copy link"); }, 1200);
    });
    card.appendChild(copy);
    card.appendChild(button(t("ChatWeb_OpenInApp", "Open in PullYard"), "small primary", function () { send({ type: "link", id: pr.url }); }));
    return card;
  }

  function banner() {
    var b = el("div", "banner" + (meta.authExpired ? " auth" : ""));
    var row = el("div", "row");
    if (meta.authExpired) {
      b.appendChild(el("div", "btitle", icon("person") + "<span>" + esc(t("ChatWeb_SignInExpired", "Claude sign-in expired")) + "</span>"));
      b.appendChild(el("div", "bhint", esc(meta.reauthWaiting ? t("ChatWeb_SignInWaitingHint", "Finish signing in in the terminal. The session picks up where it stopped.") : t("ChatWeb_SignInHint", "Sign in again and the session resumes where it stopped."))));
      var detail = el("div", "bdetail");
      detail.textContent = meta.lastError;
      b.appendChild(detail);
      var signIn = el("button", "b small primary", (meta.reauthWaiting ? '<span class="spin"></span>' : "") + "<span>" + esc(meta.reauthWaiting ? t("ChatWeb_WaitingSignIn", "Waiting for sign-in…") : t("ChatWeb_SignInAgain", "Sign in again")) + "</span>");
      signIn.disabled = !!meta.reauthWaiting;
      signIn.addEventListener("click", function (e) {
        e.stopPropagation();
        send({ type: "reauth" });
      });
      row.appendChild(signIn);
    } else {
      var m = el("div", "msg");
      m.textContent = "⚠ " + meta.lastError;
      b.appendChild(m);
    }
    row.appendChild(button(t("ChatWeb_RestartSession", "Restart session"), "small", function () { send({ type: "restart" }); }));
    b.appendChild(row);
    return b;
  }

  function renderTail() {
    var tail = document.getElementById("tail");
    tail.innerHTML = "";
    if (!items.length && !meta.lastError) tail.appendChild(welcome());
    if (meta.createdPR) tail.appendChild(prCard(meta.createdPR));
    if (meta.busy) {
      var wk = el("div", "working");
      wk.innerHTML = '<span class="spin"></span><span>' + esc(meta.status || (meta.pendingCount > 0 ? "Waiting for you" : "Working…")) + '</span><span class="secs" id="secs"></span><span class="sp"></span>';
      wk.appendChild(button("Stop", "small", function () { send({ type: "stop" }); }));
      tail.appendChild(wk);
      tick();
      if (!tickTimer) tickTimer = setInterval(tick, 1000);
    } else if (tickTimer) {
      clearInterval(tickTimer);
      tickTimer = null;
    }
    if (meta.lastError) tail.appendChild(banner());
  }

  function ring(done, total) {
    var c = 2 * Math.PI * 6;
    var p = total ? done / total : 0;
    return '<svg class="ring" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" class="track"/><circle cx="8" cy="8" r="6" class="fill" stroke-dasharray="' + (c * p).toFixed(2) + " " + c.toFixed(2) + '"/></svg>';
  }

  function renderDock() {
    var dock = document.getElementById("dock");
    var todo = meta.todos;
    var visible = todo && todo.total > 0 && todo.done < todo.total;
    if (!visible) {
      if (dock.childNodes.length) {
        dock.innerHTML = "";
        dock.classList.remove("on");
        layoutDock();
      }
      return;
    }
    var sig = JSON.stringify(todo) + todoOpen;
    if (dock._sig === sig) return;
    dock._sig = sig;
    dock.innerHTML = "";
    dock.classList.add("on");
    var bar = el("div", "todobar" + (todoOpen ? " open" : ""));
    if (todoOpen) {
      var list = el("div", "todolist");
      todo.todos.forEach(function (x) {
        var st = x.status || "pending";
        var r = el("div", "todo " + st);
        r.appendChild(el("span", "i", st === "completed" ? "✔" : st === "in_progress" ? "◉" : "○"));
        var tt = el("span", "t");
        tt.textContent = x.title;
        r.appendChild(tt);
        list.appendChild(r);
      });
      bar.appendChild(list);
    }
    var head = el("button", "todohead", ring(todo.done, todo.total) + '<span class="count">' + todo.done + "/" + todo.total + '</span><span class="cur">' + esc(todo.current || "") + "</span>" + icon("chev", "chev"));
    head.addEventListener("click", function () {
      todoOpen = !todoOpen;
      dock._sig = null;
      renderDock();
    });
    bar.appendChild(head);
    dock.appendChild(bar);
    layoutDock();
  }

  function layoutDock() {
    var dock = document.getElementById("dock");
    var h = dock.classList.contains("on") ? dock.offsetHeight : 0;
    document.documentElement.style.setProperty("--dock", h + "px");
    document.body.style.paddingBottom = (24 + h) + "px";
    repin();
  }

  function tick() {
    var secs = document.getElementById("secs");
    if (secs && meta.turnStartedAt) secs.textContent = Math.max(0, Math.floor((Date.now() - meta.turnStartedAt) / 1000)) + "s";
  }

  function buildChrome() {
    var jump = el("button", "jump", '<span class="halo"></span>' + icon("down") + '<span class="badge"></span>');
    jump.id = "jump";
    jump.tabIndex = -1;
    jump.addEventListener("click", function (e) {
      e.stopPropagation();
      jumpToLatest();
    });
    document.body.appendChild(jump);
    var dock = el("div", "");
    dock.id = "dock";
    document.body.appendChild(dock);
    updateJump();
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
    if (!msg) return;
    switch (msg.op) {
      case "vars":
        document.getElementById("vars").textContent = msg.css;
        break;
      case "strings":
        strings = msg.strings || {};
        Object.keys(nodes).forEach(function (k) { nodes[k]._sig = null; });
        preserving(function () { render(); renderTail(); updateJump(); });
        break;
      case "reset":
        if (msg.meta) meta = msg.meta;
        reset(msg.items || []);
        break;
      case "upsert":
        if (msg.meta) meta = msg.meta;
        upsert(msg.items || []);
        break;
      case "meta":
        meta = msg.meta;
        preserving(function () { renderTail(); renderDock(); });
        break;
      case "bottom":
        scrollDown();
        updateJump();
        break;
    }
  }

  document.addEventListener("click", function (e) {
    var a = e.target instanceof Element ? e.target.closest("a[href]") : null;
    if (!a) return;
    e.preventDefault();
    var href = a.getAttribute("href") || "";
    if (href.charAt(0) === "#") return;
    send({ type: "link", id: href });
  }, true);

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && meta.busy) send({ type: "stop" });
  });

  document.addEventListener("keydown", function (e) {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    var key = e.key.toLowerCase();
    var app = !e.shiftKey && key === "k" ? "quickopen" : !e.shiftKey && key === "n" ? "new" : e.shiftKey && (e.key === "}" || e.key === "]") ? "next" : e.shiftKey && (e.key === "{" || e.key === "[") ? "prev" : null;
    if (app) {
      e.preventDefault();
      send({ type: "app", id: app });
    }
  }, true);

  document.addEventListener("keydown", function (e) {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    var id = e.key === "=" || e.key === "+" ? "in" : e.key === "-" || e.key === "_" ? "out" : e.key === "0" ? "reset" : null;
    if (!id) return;
    e.preventDefault();
    send({ type: "zoom", id: id });
  }, true);

  if (host) host.addEventListener("message", onMessage);
  document.addEventListener("DOMContentLoaded", function () {
    buildChrome();
    renderTail();
    send({ type: "ready" });
  });
})();
