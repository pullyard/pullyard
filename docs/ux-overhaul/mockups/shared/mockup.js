(function () {
  const q = new URLSearchParams(location.search);
  const platform = q.get("platform") || document.documentElement.dataset.platform || "windows";
  const screen = q.get("screen") || "main";
  const theme = q.get("theme") || "light";
  const variant = q.get("variant") || "proposed";
  const root = document.documentElement;
  root.dataset.platform = platform;
  root.dataset.theme = theme;
  root.dataset.variant = variant;

  const icons = {
    bell: '<path d="M8 2a4 4 0 0 0-4 4v3l-1.5 2h11L12 9V6a4 4 0 0 0-4-4Zm-1.5 11a1.5 1.5 0 0 0 3 0"/>',
    eye: '<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/>',
    user: '<circle cx="8" cy="5.5" r="2.5"/><path d="M3 13.5c.6-2.5 2.6-4 5-4s4.4 1.5 5 4"/>',
    at: '<circle cx="8" cy="8" r="2.5"/><path d="M10.5 8v1a1.75 1.75 0 0 0 3.5 0V8a6 6 0 1 0-2.4 4.8"/>',
    check: '<path d="M3 8.5 6.5 12 13 4.5"/>',
    folder: '<path d="M2 4.5h4l1.5 1.5H14v6.5H2Z"/>',
    stack: '<path d="M8 2 14 5 8 8 2 5Z"/><path d="m2 8 6 3 6-3"/><path d="m2 11 6 3 6-3"/>',
    issue: '<circle cx="8" cy="8" r="5.5"/><circle cx="8" cy="8" r="1"/>',
    repo: '<path d="M3.5 2.5h8v11h-8a1.5 1.5 0 0 1 0-3h8"/>',
    board: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10M10 3v10"/>',
    term: '<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="m4.5 6 2 2-2 2M8 10h3.5"/>',
    pr: '<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="12.5" r="1.5"/><path d="M4.5 5v6M11.5 11V6.5a2 2 0 0 0-2-2H7"/><path d="m8.5 3-1.5 1.5L8.5 6"/>',
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/>',
    gear: '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/>',
    refresh: '<path d="M13 8a5 5 0 1 1-1.5-3.6"/><path d="M13 2.5v3h-3"/>',
    merge: '<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="8" r="1.5"/><path d="M4.5 5v6M4.5 5c0 3 3 3 5.5 3"/>',
    x: '<path d="m4 4 8 8M12 4l-8 8"/>',
    warn: '<path d="M8 2 14.5 13.5h-13Z"/><path d="M8 6.5v3M8 11.5v.01"/>',
    chat: '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2Z"/>',
    commit: '<circle cx="8" cy="8" r="2.5"/><path d="M1.5 8h4M10.5 8h4"/>',
    list: '<path d="M5.5 4h8M5.5 8h8M5.5 12h8M2.5 4h.01M2.5 8h.01M2.5 12h.01"/>',
    file: '<path d="M4 1.5h5l3 3v10H4Z"/><path d="M9 1.5v3h3"/>',
    wrench: '<path d="M10.5 2a3 3 0 0 0-2.8 4.1L2.5 11.3a1.4 1.4 0 0 0 2 2l5.2-5.2A3 3 0 0 0 13.9 5l-1.8 1.8-1.9-.5-.5-1.9Z"/>',
    chev: '<path d="m6 4 4 4-4 4"/>',
    up: '<path d="m4 10 4-4 4 4"/>',
    down: '<path d="m4 6 4 4 4-4"/>',
    bubble: '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2Z"/><path d="M5 6.5h6M5 8.5h4"/>',
    menu: '<path d="M2.5 4h11M2.5 8h11M2.5 12h11"/>',
    back: '<path d="m9.5 3.5-4.5 4.5 4.5 4.5"/>',
    people: '<circle cx="6" cy="5.5" r="2.2"/><circle cx="11.5" cy="6" r="1.8"/><path d="M2 13c.5-2.2 2-3.5 4-3.5s3.5 1.3 4 3.5M10.5 9.6c1.7 0 3 1.1 3.5 3"/>',
    plus: '<path d="M8 3v10M3 8h10"/>',
    puzzle: '<path d="M3 6h2.5a1.5 1.5 0 1 1 3 0H11v2.5a1.5 1.5 0 1 1 0 3V14H3Z"/>'
  };
  const I = (n, c = "") => `<svg class="ic ${c}" viewBox="0 0 16 16" aria-hidden="true">${icons[n] || ""}</svg>`;

  const prs = [
    { n: 45, t: "macOS: full merge request review for GitLab", a: "Vaache", ago: "2 wk", add: 1580, del: 110, ci: "fail", st: "open", rv: "Review required" },
    { n: 37, t: "Linux: Flathub-ready manifest, offline build, metainfo", a: "Vaache", ago: "2 wk", add: 7411, del: 103, ci: "fail", st: "open", rv: "Changes requested" },
    { n: 36, t: "winget: manifests and release automation", a: "Vaache", ago: "2 wk", add: 268, del: 0, ci: "pass", st: "open", rv: "Approved" },
    { n: 58, t: "macOS: smoother sidebars, chat, diffs and agent tools", a: "Vaache", ago: "3 d", add: 2104, del: 877, ci: "pass", st: "merged", rv: "Approved" },
    { n: 57, t: "Site: Umami analytics, stats dashboard and refreshed live demo", a: "Vaache", ago: "5 d", add: 912, del: 240, ci: "run", st: "draft", rv: "Draft" }
  ];

  const isWin = platform === "windows";
  const cur = variant === "current";
  const mod = "Ctrl";

  function titlebar(title, sub) {
    if (isWin) {
      if (cur) {
        return `<div class="tb tb-win cur"><div class="tb-app"><span class="logo"></span>PullYard <span class="tb-sub">${sub ? "— " + sub : ""}</span></div><div class="flex"></div><div class="caps"><span></span><span></span><span></span></div></div>`;
      }
      return `<div class="tb tb-win"><button class="tb-btn" title="Back (Alt+Left)">${I("back")}</button><button class="tb-btn" title="Toggle pane (Ctrl+Shift+S)">${I("menu")}</button><div class="tb-app"><span class="logo"></span>PullYard</div><div class="tb-search">${I("search")}<span>Search pull requests, repos, sessions</span><kbd>Ctrl+K</kbd></div><div class="flex"></div><div class="caps"><span class="cap">${capGlyph("min")}</span><span class="cap">${capGlyph("max")}</span><span class="cap close">${capGlyph("close")}</span></div></div>`;
    }
    return `<div class="tb tb-gtk"><div class="tb-left"><button class="tb-btn" title="Toggle sidebar (F9)">${I("menu")}</button><button class="tb-btn" title="Back (Alt+Left)">${I("back")}</button></div><div class="tb-title"><b>${title}</b>${sub && sub !== title ? `<span>${sub}</span>` : ""}</div><div class="tb-right"><button class="tb-btn" title="Search (Ctrl+K)">${I("search")}</button><button class="tb-btn" title="Main menu">${I("menu")}</button><span class="gtk-close">${capGlyph("close")}</span></div></div>`;
  }
  function capGlyph(k) {
    const p = { min: '<path d="M3 8h10"/>', max: '<rect x="3.5" y="3.5" width="9" height="9" rx="1"/>', close: '<path d="m4 4 8 8M12 4l-8 8"/>' }[k];
    return `<svg class="ic" viewBox="0 0 16 16">${p}</svg>`;
  }

  function sidebar(active) {
    const groups = [
      ["Inbox", [["bell", "Notifications", 12, "amber"]]],
      ["Pull requests", [["eye", "Review requests", 3, "sky"], ["user", "Created by me", 7, "violet"], ["user", "Assigned to me", 0, "teal"], ["at", "Mentioned", 0, "indigo"], ["check", "Reviewed by me", 0, "green"], ["folder", "My PRs by project", 0, "coral"], ["stack", "Stacks", 0, "indigo"]]],
      ["Issues", [["issue", "Assigned to me", 0, "teal"], ["issue", "Created by me", 0, "green"]]],
      ["Code", [["repo", "Repositories", 0, "teal"], ["board", "Projects", 0, "indigo"]]],
      ["AI", [["term", "Agents", 1, "coral"]]]
    ];
    let h = `<nav class="side" aria-label="Sections">`;
    for (const [g, rows] of groups) {
      h += `<div class="sg">${g}</div>`;
      for (const [ic, t, c, col] of rows) {
        const sel = t === active;
        h += `<div class="sr ${sel ? "sel" : ""}" style="--hue:var(--${col})"><span class="si">${I(ic)}</span><span class="st">${t}</span>${c ? `<span class="sc">${c}</span>` : ""}</div>`;
      }
    }
    h += `<div class="flex"></div><div class="acct"><span class="av">AR</span><div><b>Alex Rivera</b><small>@arivera · GitHub</small></div><span class="flex"></span><button class="ib" title="Switch account">${I("people")}</button><button class="ib" title="Settings (${mod}+,)">${I("gear")}</button></div></nav>`;
    return h;
  }

  function ciChip(ci) {
    if (ci === "fail") return `<span class="chip red">${I("x")}Checks failing</span>`;
    if (ci === "run") return `<span class="chip amber">${I("refresh")}Running</span>`;
    return `<span class="chip green">${I("check")}Checks passed</span>`;
  }
  function stateIcon(st) {
    const map = { open: ["pr", "green", "Open"], draft: ["pr", "slate", "Draft"], merged: ["merge", "violet", "Merged"], closed: ["x", "red", "Closed"] };
    const [ic, col, label] = map[st];
    return `<span class="sticon" style="--hue:var(--${col})" title="${label}">${I(ic)}</span>`;
  }

  function list(selected) {
    let h = `<section class="list"><div class="lh"><div><b>Review requests</b><small>3 results · updated just now</small></div><button class="ib" title="Refresh (${mod}+R)">${I("refresh")}</button></div>`;
    h += `<div class="seg"><span class="on">Open</span><span>Closed</span><span>All</span></div>`;
    if (!cur) h += `<div class="filter">${I("search")}<span>Filter: text, repo:org/name, label:bug</span></div>`;
    for (const p of prs.slice(0, cur ? 3 : 5)) {
      const sel = p.n === selected;
      h += `<div class="row ${sel ? "sel" : ""}">${stateIcon(p.st)}<div class="rb"><div class="rt">${p.t}</div><div class="rm">pullyard/pullyard#${p.n} · ${p.ago} ago · <span class="add">+${p.add.toLocaleString("en-US")}</span> <span class="del">−${p.del}</span></div>${cur ? `<div class="rm"><span class="avs">V</span> ${p.a}<span class="flex"></span><span class="xred">✕</span></div>` : `<div class="rm2"><span class="avs">V</span>${p.a}<span class="flex"></span>${ciChip(p.ci)}</div>`}</div></div>`;
    }
    h += `</section>`;
    return h;
  }

  function prHeader() {
    return `<div class="ph"><div class="ptitle"><h1>macOS: full merge request review for GitLab <span class="num">#45</span></h1></div>
      <div class="pmeta"><span class="badge open">${I("pr")}Open</span><span class="avs">V</span><b>Vaache</b> wants to merge <code class="br">claude/gitlab-mr-review-macos</code> into <code class="br base">main</code><span class="add">+1,580</span><span class="del">−110</span><span class="flex"></span><span class="muted">updated 2 wk ago</span></div>
      <div class="banner red">${I("warn")}<span><b>Has conflicts with main.</b> 6 files need resolving before this can merge.</span><span class="flex"></span><button class="btn">View conflicts</button><button class="btn">Resolve with agent…</button><button class="btn" title="Not ready to merge">Merge…</button></div>
      <div class="banner red soft">${I("x")}<span><b>1 check failing</b> · macOS / build</span><span class="flex"></span><button class="btn">Re-run failed</button><button class="btn accent">Fix with agent</button></div></div>`;
  }
  function tabs(active) {
    const t = [["chat", "Conversation", "3"], ["commit", "Commits", "1"], ["list", "Checks", "1 failing"], ["file", "Files changed", "17"]];
    return `<div class="tabs" role="tablist">${t.map(([i, n, b]) => `<span class="tab ${n === active ? "on" : ""}" role="tab">${I(i)}${n}<span class="tb-badge ${n === "Checks" ? "red" : ""}">${b}</span></span>`).join("")}<span class="flex"></span><span class="hint">${mod}+Shift+1–4</span></div>`;
  }
  function toolbar() {
    return `<div class="dtb"><span class="muted small">${I("refresh")} just now</span><span class="flex"></span><button class="btn">${I("bubble")}Review</button><button class="btn">${I("wrench")}Fix with agent</button><button class="btn">${I("merge")}Merge</button><button class="ib" title="Open in browser">${I("chev")}</button><button class="ib" title="More">⋯</button></div>`;
  }

  function conversation() {
    const c = (who, when, body, cls = "") => `<div class="cmt ${cls}"><span class="av">${who[0]}</span><div class="cb"><div class="ch"><b>${who}</b> <span class="muted">${when}</span></div><div class="cx">${body}</div></div></div>`;
    return `<div class="conv">${c("Vaache", "described · 2 wk ago", "<p>GitLab merge requests now open in the PR detail view, the same way a GitHub pull request does.</p><ul><li><b>Provider-neutral detail model:</b> <code>PRDetailModel</code> talks to a <code>PRBackend</code>.</li><li><b>PRFeatures</b> turns off GitHub-only actions for GitLab.</li><li>Pipeline jobs in the Pipeline tab; changed files from <code>/diffs</code>.</li></ul>")}
      <div class="evt">${I("check")} <b>octo-reviewer</b> approved · 1 wk ago</div>
      ${c("octo-reviewer", "on Sources/PullYard/API/Forges/GitLabClient.swift · 1 wk ago", "<p>Should <code>detailed_merge_status</code> fall back to <code>merge_status</code> on GitLab &lt; 15.6?</p><div class='thread-actions'><button class='btn small'>Reply…</button><button class='btn small'>Resolve</button></div>", "thread")}
      </div><div class="composer"><div class="ta">Comment (Markdown) — ${mod}+Enter to send</div><button class="btn accent">Comment</button></div>`;
  }

  function diff() {
    const files = [["M", "ForgeClient.swift", "Sources/PullYard/API/Forges", 24, 6, true], ["M", "GitLabClient.swift", "Sources/PullYard/API/Forges", 312, 40, false], ["A", "GitLabReview.swift", "Sources/PullYard/API/Forges", 410, 0, false], ["M", "Models.swift", "Sources/PullYard/API", 38, 2, false], ["M", "AppModel.swift", "Sources/PullYard/App", 61, 19, false], ["M", "FilesTab.swift", "Sources/PullYard/Features/PR", 94, 21, false], ["A", "PRBackend.swift", "Sources/PullYard/Features/PR", 188, 0, false]];
    let fl = `<div class="files"><div class="filter">${I("search")}<span>Filter files</span><span class="flex"></span><span class="muted small">2/17 viewed</span></div>`;
    files.forEach(([k, n, d, a, r, sel], i) => {
      fl += `<div class="frow ${sel ? "sel" : ""}"><span class="fk ${k}">${k}</span><div class="rb"><div>${n}</div><small>${d}</small></div><span class="add">+${a}</span><span class="del">−${r}</span>${i === 1 ? `<span class="cc" title="2 unresolved comments">${I("bubble")}2</span>` : ""}</div>`;
    });
    fl += `</div>`;
    const L = [
      ["hunk", "", "", "@@ -50,13 +50,15 @@ protocol ForgeClient: AnyObject {"],
      ["ctx", 50, 50, "    func notifications() async throws -> [ForgeNotification]"],
      ["ctx", 51, 51, "    func markDone(_ notification: ForgeNotification) async throws"],
      ["ctx", 52, 52, "    func repositories() async throws -> [ForgeRepo]"],
      ["add", "", 53, "    func reviewBackend() -> <w>PRBackend?</w>"],
      ["ctx", 53, 54, "}"],
      ["ctx", 54, 55, ""],
      ["ctx", 55, 56, "extension ForgeClient {"],
      ["del", 56, "", "    func issues(_ filter: IssueFilter) async throws -> [SearchItem] { [] }"],
      ["add", "", 57, "    func issues(_ filter: IssueFilter, state: <w>StateFilter</w>) async throws -> [SearchItem] { [] }"],
      ["ctx", 57, 58, "    func notifications() async throws -> [ForgeNotification] { [] }"],
      ["add", "", 61, "    func reviewBackend() -> PRBackend? { nil }"],
      ["ctx", 60, 62, "}"],
      ["hunk", "", "", "@@ -121,18 +123,23 @@ final class ForgeHTTP {"],
      ["ctx", 121, 123, "        try await call(\"GET\", path, query)"],
      ["del", 124, "", "    func post(_ path: String, _ query: [URLQueryItem] = []) async throws {"],
      ["add", "", 126, "    func post(_ path: String, _ query: [URLQueryItem] = [], <w>method: String = \"POST\"</w>) async throws {"]
    ];
    let code = `<div class="diff"><div class="rbar"><button class="ib" title="Previous file (P)">${I("up")}</button><button class="ib" title="Next file (N)">${I("down")}</button><span class="sep"></span><button class="ib" title="Previous hunk ([)">[</button><button class="ib" title="Next hunk (])">]</button><span class="sep"></span><button class="ib" title="Next comment (C)">${I("bubble")}</button><span class="flex"></span><label class="cbx"><span class="box on"></span>Wrap</label><div class="seg sm"><span class="on">Unified</span><span>Split</span></div><span class="muted small">N/P files · [ ] hunks · C comments · V viewed</span></div>`;
    code += `<div class="fhead">${I("down")}<b>Sources/PullYard/API/Forges/ForgeClient.swift</b><span class="add">+24</span><span class="del">−6</span><span class="flex"></span><label class="cbx"><span class="box"></span>Viewed</label></div><div class="code">`;
    for (const [k, o, n, t] of L) {
      code += `<div class="ln ${k}"><span class="g">${o}</span><span class="g">${n}</span><span class="m">${k === "add" ? "+" : k === "del" ? "−" : ""}</span><span class="t">${t.replace(/ /g, "&nbsp;").replace(/&nbsp;<w>/g, " <w>").replace(/<w>/g, '<span class="w">').replace(/<\/w>/g, "</span>")}</span></div>`;
      if (k === "add" && n === 53) code += `<div class="ithread"><div class="ch"><span class="av">O</span><b>octo-reviewer</b> <span class="muted">1 wk ago</span><span class="flex"></span><button class="btn small">Resolve</button></div><div class="cx">Can this return a non-optional for GitHub? Callers always unwrap.</div><div class="ta small">Reply… (draft kept if you scroll away)</div></div>`;
    }
    code += `</div></div>`;
    return `<div class="split">${fl}${code}</div>`;
  }

  function detail(kind) {
    return `<section class="detail">${toolbar()}${prHeader()}${tabs(kind === "diff" ? "Files changed" : "Conversation")}${kind === "diff" ? diff() : conversation()}</section>`;
  }

  function settings() {
    const row = (t, d, ctl) => `<div class="srow"><div><div>${t}</div>${d ? `<small>${d}</small>` : ""}</div><span class="flex"></span>${ctl}</div>`;
    const tog = (on) => `<span class="toggle ${on ? "on" : ""}"><span></span></span>`;
    const sel = (v) => `<span class="select">${v}${I("down")}</span>`;
    const nav = [["gear", "General"], ["people", "Accounts"], ["puzzle", "Integrations"], ["wrench", "Advanced"]];
    let h = `<section class="settings"><aside class="snav">${nav.map(([i, n], k) => `<div class="sr ${k === 0 ? "sel" : ""}" style="--hue:var(--accent)"><span class="si">${I(i)}</span><span class="st">${n}</span></div>`).join("")}</aside><div class="spage"><h1>General</h1>`;
    h += `<h2>Appearance</h2><div class="card">${row("Theme", "PullYard brand colours or the system palette", `<div class="seg sm"><span class="on">PullYard</span><span>System</span></div>`)}${row("Mode", "", `<div class="seg sm"><span>System</span><span class="${theme === "light" ? "on" : ""}">Light</span><span class="${theme === "dark" ? "on" : ""}">Dark</span></div>`)}${row("Text size", `${mod}+ / ${mod}− / ${mod}+0`, sel("100%"))}</div>`;
    h += `<h2>Behaviour</h2><div class="card">${row("Open links in", "", sel(isWin ? "Microsoft Edge" : "Firefox"))}${row("Auto-refresh pull requests", "", sel("Every 30 seconds"))}${row(isWin ? "Keep running in the notification area when closed" : "Keep running in the background when closed", isWin ? "Shown once the first time the window hides" : "Shows a persistent notification while hidden", tog(true))}</div>`;
    h += `<h2>Notifications</h2><div class="card">${row("New review requests", "", tog(true))}${row("Checks failed on my pull requests", "", tog(true))}${row("Agent needs permission or an answer", "", tog(true))}</div>`;
    h += `<h2>Keyboard shortcuts</h2><div class="card">${row("Command palette", "", `<kbd>${mod}+K</kbd>`)}${row("Open by link", "", `<kbd>${mod}+L</kbd>`)}${row("Back", "", `<kbd>Alt+Left</kbd>`)}${row("All shortcuts", "", `<kbd>${mod}+?</kbd>`)}</div>`;
    h += `</div></section>`;
    return h;
  }

  function currentSettings() {
    return `<div class="dim-overlay"></div><div class="cdialog"><h3>Settings</h3><div class="cscroll"><b>Appearance</b><p>Theme: PullYard · Mode: Match system</p><b>Account</b><p>Alex Rivera · @arivera</p><b>Links</b><p>Open links in: Default browser</p><b>Refresh</b><p>Every 30 seconds</p><b>Notifications</b><p>…</p><b>Agents</b><p>…</p><b>Updates</b><p>…</p></div><div class="cbtns"><span class="btn accent">Close</span></div></div>`;
  }

  let body = "";
  const sub = screen === "detail" || screen === "diff" ? "pullyard/pullyard #45" : screen === "settings" ? "Settings" : "Review requests";
  const title = screen === "settings" ? "Settings" : screen === "main" ? "Review requests" : "macOS: full merge request review for GitLab";
  if (screen === "settings" && !cur) {
    body = settings();
  } else {
    const compactNav = cur && isWin && window.innerWidth < 1180;
    body = `${compactNav ? sidebarRail() : sidebar("Review requests")}${list(screen === "main" ? 0 : 45)}${screen === "main" ? `<section class="detail empty"><div class="ph-empty"><span class="tile">${I("pr")}</span><p>Select a pull request, issue or project</p><small>${mod}+L to open by link · ${mod}+K for the command palette</small></div></section>` : detail(screen)}`;
    if (screen === "settings") body += currentSettings();
  }
  function sidebarRail() {
    const ics = ["bell", "eye", "user", "user", "at", "check", "folder", "stack", "issue", "issue", "repo", "board", "term"];
    return `<nav class="rail">${ics.map((i, k) => `<span class="ri ${k === 1 ? "sel" : ""}">${I(i)}</span>`).join("")}</nav>`;
  }
  const label = cur ? "Reconstruction of the current layout (from source, not a screenshot)" : "Mockup — proposed design, not a screenshot of a running build";
  document.body.innerHTML = `<div class="win">${titlebar(title, sub)}<div class="shell">${body}</div><div class="stamp">${label} · ${isWin ? "Windows 11" : "Linux (GTK 4 / libadwaita)"} · ${theme}</div></div>`;
})();
