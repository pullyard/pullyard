(function () {
  var root = document.getElementById("demo");
  if (!root) return;

  var ICONS = {
    bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
    eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',
    at: '<circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/>',
    book: '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20V3H6.5A2.5 2.5 0 0 0 4 5.5z"/><path d="M4 19.5V21h16"/>',
    board: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/>',
    spark: '<path d="m12 3 1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/>',
    pr: '<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="18" r="2.5"/><path d="M6 8.5v7M18 15.5V10a3 3 0 0 0-3-3h-4"/><path d="m13 5-2 2 2 2"/>',
    merge: '<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="12" r="2.5"/><path d="M6 8.5v7M6 8.5c0 3 3 3.5 9.5 3.5"/>',
    chat: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    commit: '<circle cx="12" cy="12" r="3.5"/><path d="M3 12h5.5M15.5 12H21"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    x: '<path d="M18 6 6 18M6 6l12 12"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    file: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    back: '<path d="m15 18-6-6 6-6"/>',
    term: '<path d="m4 17 6-6-6-6M12 19h8"/>',
    edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
    send: '<path d="M12 19V5M5 12l7-7 7 7"/>',
    stack: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    ticket: '<path d="M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 0 0 4v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3a2 2 0 0 0 0-4z"/><path d="M14 6v2M14 11v2M14 16v2"/>',
    unified: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 12h18"/>',
    split: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4L21 8"/><path d="M21 3v5h-5"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    branch: '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="7" r="2"/><path d="M6 7v10M18 9c0 5-6 4-11 8"/>',
    panel: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/>',
    push: '<path d="M12 16V4M6 10l6-6 6 6"/><path d="M4 20h16"/>',
    note: '<path d="M4 4h16v11l-5 5H4z"/><path d="M15 20v-5h5"/>',
    chev: '<path d="m9 6 6 6-6 6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>'
  };
  function icon(name, cls) {
    return '<svg class="' + (cls || "ic") + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + "</svg>";
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function avatar(name) {
    var hues = { mkato: "#34d399,#4aa8dc", jlee: "#e8b44c,#f472b6", sofia: "#9d8cf0,#5bb8ec", dvorak: "#ee6f5f,#f59e0b", bot: "#5f6b80,#94a3b8", arivera: "#f472b6,#818cf8" };
    return '<span class="d-av" style="background:' + (hues[name] || "#5f6b80,#94a3b8").split(",")[0] + '"></span>';
  }

  var KEYWORDS = ["const", "let", "var", "function", "return", "if", "else", "import", "from", "export", "await", "async", "new", "guard", "struct", "func", "self", "true", "false", "null", "it", "describe", "try", "catch", "finally", "type", "jobs"];
  function hl(src) {
    var re = /(\/\/.*$)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)/g;
    var out = "", last = 0, m;
    while ((m = re.exec(src))) {
      out += esc(src.slice(last, m.index));
      var cls = m[1] ? "hc" : m[2] ? "hs" : m[3] ? "hn" : KEYWORDS.indexOf(m[4]) >= 0 ? "hk" : src.charAt(re.lastIndex) === "(" ? "hf" : /^[A-Z]/.test(m[4]) ? "ht" : "";
      out += cls ? '<span class="' + cls + '">' + esc(m[0]) + "</span>" : esc(m[0]);
      last = re.lastIndex;
    }
    return out + esc(src.slice(last));
  }

  var PRS = {
    91: {
      repo: "acme/ios", title: "Haptics on pull to refresh", author: "dvorak", state: "open", ago: "now", add: 22, del: 3, base: "main", head: "feat/pull-haptics",
      body: "Plays a light haptic when the pull crosses the refresh threshold, once per gesture.",
      commits: [["Add haptic at refresh threshold", "dvorak", "now"]],
      checks: [["run", "build", "running"], ["ok", "lint", "18s"]],
      files: [{ path: "Sources/Shared/PullIndicator.swift", st: "M", add: 22, del: 3, lines: [
        ["h", "", "", "@@ -12,6 +12,9 @@ struct PullIndicator: View {"],
        ["", "12", "12", "    .onChange(of: armed) { _, armed in"],
        ["a", "", "13", "        guard armed else { return }"],
        ["a", "", "14", "        haptics.perform(.alignment, performanceTime: .now)"],
        ["", "13", "15", "    }"]
      ] }]
    },
    480: {
      repo: "acme/web-app", title: "Search index endpoint", author: "mkato", state: "merged", ago: "3d", add: 131, del: 8, base: "main", head: "feat/search-index", stack: "search",
      body: "Adds <code>GET /search</code> backed by the new index. First PR in the search stack.",
      commits: [["Search index endpoint", "mkato", "3d"], ["Index tests", "mkato", "3d"]],
      checks: [["ok", "build", "1m 08s"], ["ok", "unit tests", "51s"]],
      files: [{ path: "src/api/search.ts", st: "A", add: 24, del: 0, lines: [
        ["h", "", "", "@@ -0,0 +1,24 @@"],
        ["a", "", "1", "export async function fetchResults(query: string) {"],
        ["a", "", "2", "  const res = await fetch(`/search?q=${encodeURIComponent(query)}`)"],
        ["a", "", "3", "  return res.json()"],
        ["a", "", "4", "}"]
      ] }]
    },
    482: {
      repo: "acme/web-app", title: "Speed up search with debounced queries", author: "mkato", state: "open", ago: "2h", add: 48, del: 12, base: "main", head: "feat/search-debounce", stack: "search",
      jira: { key: "WEB-214", title: "Search fires a request on every keystroke", type: "Story", prio: "High", who: "mkato", parent: "WEB-200 Search revamp" },
      body: "Debounces the search box by 250 ms so we stop firing a request on every keystroke. Adds a small <code>useDebounce</code> hook with tests.",
      rerequest: { who: "sofia", n: 2 },
      review: { who: "sofia", text: "Cancel the in-flight request when the query changes, otherwise stale results can win the race.", file: "src/search/useSearch.ts", line: 26 },
      commits: [["Add useDebounce hook", "mkato", "3h"], ["Debounce search queries", "mkato", "3h"], ["Show spinner while loading", "mkato", "2h"], ["Address lint", "mkato", "2h"]],
      checks: [["ok", "build", "1m 12s"], ["ok", "unit tests", "48s"], ["ok", "lint", "21s"], ["ok", "e2e / chrome", "3m 40s"]],
      files: [
        { path: "src/search/useSearch.ts", st: "M", add: 18, del: 6, lines: [
          ["h", "", "", "@@ -18,9 +18,15 @@ export function useSearch(query) {"],
          ["", "18", "18", "  const [results, setResults] = useState([])"],
          ["", "19", "19", "  const [loading, setLoading] = useState(false)"],
          ["d", "20", "", "  useEffect(() => {"],
          ["d", "21", "", "    fetchResults(query).then(setResults)"],
          ["d", "22", "", "  }, [query])"],
          ["a", "", "20", "  const debounced = useDebounce(query, 250)"],
          ["a", "", "21", ""],
          ["a", "", "22", "  useEffect(() => {"],
          ["a", "", "23", "    if (!debounced) return setResults([])"],
          ["a", "", "24", "    setLoading(true)"],
          ["a", "", "25", "    fetchResults(debounced)"],
          ["a", "", "26", "      .then(setResults)"],
          ["a", "", "27", "      .finally(() => setLoading(false))"],
          ["a", "", "28", "  }, [debounced])"],
          ["", "23", "29", ""],
          ["", "24", "30", "  return { results, loading }"]
        ] },
        { path: "src/hooks/useDebounce.ts", st: "A", add: 14, del: 0, lines: [
          ["h", "", "", "@@ -0,0 +1,14 @@"],
          ["a", "", "1", "import { useEffect, useState } from \"react\""],
          ["a", "", "2", ""],
          ["a", "", "3", "export function useDebounce<T>(value: T, ms: number) {"],
          ["a", "", "4", "  const [debounced, setDebounced] = useState(value)"],
          ["a", "", "5", "  useEffect(() => {"],
          ["a", "", "6", "    const id = setTimeout(() => setDebounced(value), ms)"],
          ["a", "", "7", "    return () => clearTimeout(id)"],
          ["a", "", "8", "  }, [value, ms])"],
          ["a", "", "9", "  return debounced"],
          ["a", "", "10", "}"]
        ] },
        { path: "src/search/SearchBar.test.tsx", st: "M", add: 16, del: 6, lines: [
          ["h", "", "", "@@ -12,8 +12,18 @@ describe(\"SearchBar\", () => {"],
          ["d", "12", "", "  it(\"fetches on every keystroke\", async () => {"],
          ["a", "", "12", "  it(\"waits 250 ms before fetching\", async () => {"],
          ["", "13", "13", "    render(<SearchBar />)"],
          ["a", "", "14", "    vi.useFakeTimers()"],
          ["", "14", "15", "    await user.type(input, \"ship\")"],
          ["a", "", "16", "    expect(fetchResults).not.toHaveBeenCalled()"],
          ["a", "", "17", "    vi.advanceTimersByTime(250)"],
          ["", "15", "18", "    expect(fetchResults).toHaveBeenCalledTimes(1)"]
        ] }
      ]
    },
    485: {
      repo: "acme/web-app", title: "Saved searches", author: "mkato", state: "draft", ago: "1h", add: 76, del: 4, base: "feat/search-debounce", head: "feat/saved-searches", stack: "search",
      body: "Lets people pin a query. Stacked on #482 so it reuses the debounced hook.",
      commits: [["Saved searches store", "mkato", "1h"]],
      checks: [["run", "unit tests", "running"], ["ok", "lint", "17s"]],
      files: [{ path: "src/search/saved.ts", st: "A", add: 18, del: 0, lines: [
        ["h", "", "", "@@ -0,0 +1,18 @@"],
        ["a", "", "1", "export function useSavedSearches() {"],
        ["a", "", "2", "  const [saved, setSaved] = useStoredState(\"saved-searches\", [])"],
        ["a", "", "3", "  return { saved, save: (q: string) => setSaved([...saved, q]) }"],
        ["a", "", "4", "}"]
      ] }]
    },
    479: {
      repo: "acme/web-app", title: "Add dark mode to the settings screen", author: "jlee", state: "open", ago: "5h", add: 214, del: 37, base: "main", head: "feat/dark-settings",
      body: "Moves settings colors to theme tokens and adds a light / dark / system picker.",
      commits: [["Theme tokens for settings", "jlee", "6h"], ["Appearance picker", "jlee", "5h"]],
      checks: [["ok", "build", "1m 05s"], ["run", "unit tests", "running"], ["ok", "lint", "19s"]],
      files: [{ path: "src/settings/Appearance.tsx", st: "A", add: 62, del: 0, lines: [
        ["h", "", "", "@@ -0,0 +1,62 @@"],
        ["a", "", "1", "export function AppearancePicker() {"],
        ["a", "", "2", "  const [mode, setMode] = useAppearance()"],
        ["a", "", "3", "  return <Segmented value={mode} onChange={setMode}"],
        ["a", "", "4", "    options={[\"light\", \"dark\", \"system\"]} />"],
        ["a", "", "5", "}"]
      ] }]
    },
    213: {
      repo: "acme/api", title: "Retry token refresh on 401", author: "sofia", state: "draft", ago: "yesterday", add: 92, del: 18, base: "main", head: "fix/refresh-retry",
      body: "Retries the original request once after a successful token refresh. Still needs tests for the concurrent case.",
      commits: [["Retry once after refresh", "sofia", "1d"]],
      checks: [["fail", "unit tests", "2 failed"], ["ok", "build", "58s"]],
      files: [{ path: "src/auth/client.ts", st: "M", add: 92, del: 18, lines: [
        ["h", "", "", "@@ -40,6 +40,14 @@ async function request(req) {"],
        ["", "40", "40", "  const res = await fetch(req)"],
        ["a", "", "41", "  if (res.status === 401 && !req.retried) {"],
        ["a", "", "42", "    await refreshToken()"],
        ["a", "", "43", "    return request({ ...req, retried: true })"],
        ["a", "", "44", "  }"],
        ["", "41", "45", "  return res"]
      ] }]
    },
    77: {
      repo: "acme/ios", title: "Fix crash when the list is empty", author: "arivera", state: "merged", ago: "2d", add: 9, del: 3, base: "main", head: "fix/empty-list",
      body: "Guards against an empty array before reading the first item.",
      commits: [["Guard empty list", "arivera", "2d"]],
      checks: [["ok", "build", "4m 02s"], ["ok", "tests", "2m 10s"]],
      files: [{ path: "App/Feed/FeedView.swift", st: "M", add: 9, del: 3, lines: [
        ["h", "", "", "@@ -31,7 +31,9 @@ struct FeedView: View {"],
        ["d", "31", "", "        let first = items[0]"],
        ["a", "", "31", "        guard let first = items.first else {"],
        ["a", "", "32", "            return AnyView(EmptyFeed())"],
        ["a", "", "33", "        }"]
      ] }]
    },
    58: {
      repo: "acme/infra", title: "Bump dependencies for Q4", author: "arivera", state: "open", ago: "1d", add: 140, del: 131, base: "main", head: "chore/deps-q4",
      body: "Routine dependency bumps. Node 22, Terraform providers and the CI images.",
      commits: [["Bump node to 22", "arivera", "1d"], ["Bump terraform providers", "arivera", "1d"]],
      checks: [["fail", "plan / staging", "failed"], ["ok", "lint", "12s"]],
      files: [{ path: ".github/workflows/ci.yml", st: "M", add: 2, del: 2, lines: [
        ["h", "", "", "@@ -9,7 +9,7 @@ jobs:"],
        ["d", "9", "", "      node-version: 20"],
        ["a", "", "9", "      node-version: 22"]
      ] }]
    }
  };

  var STACKS = { search: { title: "Search revamp", repo: "acme/web-app", prs: [480, 482, 485] } };

  var SECTIONS = [
    { h: "Inbox" },
    { id: "notifications", title: "Notifications", icon: "bell", color: "#e8b44c", count: 4 },
    { h: "Pull requests" },
    { id: "review", title: "Review requests", icon: "eye", color: "#5bb8ec", count: 3, list: [482, 479, 213] },
    { id: "mine", title: "Created by me", icon: "user", color: "#9d8cf0", count: 2, list: [77, 58] },
    { id: "mentioned", title: "Mentioned", icon: "at", color: "#818cf8", list: [213] },
    { id: "stacks", title: "Stacks", icon: "stack", color: "#6366f1" },
    { h: "Code" },
    { id: "repos", title: "Repositories", icon: "book", color: "#2dd4bf" },
    { id: "projects", title: "Projects", icon: "board", color: "#6366f1" },
    { h: "AI" },
    { id: "agents", title: "Agents", icon: "term", color: "#ee6f5f" }
  ];

  var NOTIFS = [
    { pr: 482, type: "pr", text: "sofia requested changes", reason: "review requested" },
    { pr: 58, type: "fail", text: "CI failed on plan / staging", reason: "ci activity" },
    { pr: 479, type: "pr", text: "jlee requested your review", reason: "review requested" },
    { pr: 77, type: "merge", text: "Merged into main", reason: "author" }
  ];

  var REPOS = [
    ["acme/web-app", "TypeScript", "#3178c6", "Customer web app", 128],
    ["acme/api", "Go", "#00add8", "Public REST API", 64],
    ["acme/ios", "Swift", "#f05138", "iOS client", 51],
    ["acme/infra", "HCL", "#844fba", "Terraform and CI", 12]
  ];

  var JIRA_FLOW = [["To Do", "#94a3b8"], ["In Progress", "#5bb8ec"], ["In Review", "#9d8cf0"], ["Done", "#5dbe8a"]];

  var SCRIPT = [
    { k: "user", text: "Address the review on #482: cancel stale search requests when the query changes." },
    { k: "text", text: "I'll pass an <code>AbortSignal</code> to <code>fetchResults</code> and abort it when the effect re-runs." },
    { k: "group", id: "g1", steps: [["read", "Read src/search/useSearch.ts"], ["search", "Searched for \"fetchResults\""], ["read", "Read src/api/search.ts"]] },
    { k: "group", id: "g2", open: true, edit: true, steps: [["edit", "Edited src/search/useSearch.ts", "+3 −1"]] },
    { k: "perm" },
    { k: "group", id: "g3", open: true, task: true, steps: [["cmd", "npm test -- search"]], out: " ✓ src/search/SearchBar.test.tsx (8)\n ✓ src/hooks/useDebounce.test.ts (4)\n\n Tests  12 passed" },
    { k: "text", text: "Done. Each query now gets its own <code>AbortController</code>, so a slow response can't overwrite newer results. All 12 tests pass." },
    { k: "ship" }
  ];

  var SESSIONS = {
    saved: { title: "Saved searches", project: "web-app", branch: "feat/saved-searches", items: [
      { k: "user", text: "Add saved searches on top of #482 and open a draft PR." },
      { k: "group", id: "s1", steps: [["read", "Read src/search/useSearch.ts"], ["edit", "Edited src/search/saved.ts"], ["cmd", "npm test -- saved"]] },
      { k: "text", text: "Saved searches are stored per user and reuse the debounced query. I opened a draft stacked on #482." },
      { k: "prcard", pr: 485 }
    ] },
    params: { title: "Map query params", project: "web-app", branch: "feat/saved-searches", child: true, items: [
      { k: "user", text: "Find every place that builds a search URL." },
      { k: "group", id: "p1", steps: [["search", "Searched for \"/search?q=\""], ["read", "Read src/api/search.ts"], ["read", "Read src/search/saved.ts"]] },
      { k: "text", text: "Two call sites build the URL by hand: <code>fetchResults</code> and the saved search link. Both now go through <code>searchURL()</code>." }
    ] },
    token: { title: "Concurrent token refresh", project: "api", branch: "fix/refresh-retry", items: [
      { k: "user", text: "Why do the concurrent refresh tests fail on #213?" },
      { k: "group", id: "t1", steps: [["search", "Searched for \"refreshToken\""], ["read", "Read src/auth/client.ts"], ["cmd", "npm test -- auth"]] },
      { k: "text", text: "Two requests that get a 401 at the same time both refresh the token. Sharing one in-flight refresh fixes both failing tests." }
    ] }
  };

  var state = {
    section: "review", pr: 482, tab: "files", file: 0, filter: "open", repo: 0, detail: "pr", detailOpen: false,
    fresh: null, freshDone: false, updated: Date.now(), requested: false, rerqHidden: false,
    diffMode: "unified", viewed: {}, jira: "In Review", session: "main", chat: null, open: {},
    inspector: true, itab: "changes", palette: null, toast: null, refreshing: false
  };

  function stateColor(s) {
    return s === "merged" ? "var(--violet)" : s === "draft" ? "#94a3b8" : s === "closed" ? "var(--coral)" : "var(--green)";
  }
  function stateIcon(s) {
    return s === "merged" ? "merge" : "pr";
  }
  function stateBadge(p) {
    var col = stateColor(p.state);
    return '<span class="d-state" style="color:' + col + ";background:color-mix(in srgb," + col + ' 16%,transparent)">' + icon(stateIcon(p.state), "ti") + "</span>";
  }

  function platform() {
    return document.documentElement.getAttribute("data-platform") || "mac";
  }
  function mod() {
    return platform() === "mac" ? "⌘" : "Ctrl+";
  }
  function sendKey() {
    return platform() === "mac" ? "⌘↩" : "Ctrl+Enter";
  }
  function windowBar() {
    if (platform() === "mac") return "";
    var glyphs = ['<path d="M1 5h8"/>', '<rect x="1" y="1" width="8" height="8"/>', '<path d="m1 1 8 8M9 1 1 9"/>'];
    return '<div class="d-wc" aria-hidden="true"><b>PullYard</b><span>' + glyphs.map(function (g) { return '<i><svg viewBox="0 0 10 10">' + g + "</svg></i>"; }).join("") + "</span></div>";
  }

  function agentStatus() {
    var c = state.chat;
    if (!c || !c.items.length) return "idle";
    if (c.waiting) return "waiting";
    if (c.busy) return "working";
    return c.seen ? "idle" : "done";
  }
  var STATUS = { working: ["#5bb8ec", "Working"], waiting: ["#e8b44c", "Needs you"], done: ["#5dbe8a", "Finished"], idle: ["#5dbe8a", "Active"], sleeping: ["#5f6b80", "Sleeping"] };

  function sidebar() {
    var h = '<div class="d-side">' + (platform() === "mac" ? '<div class="d-tl"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>' : "");
    SECTIONS.forEach(function (s) {
      if (s.h) { h += '<div class="d-h">' + s.h + "</div>"; return; }
      var on = state.section === s.id ? " on" : "";
      var count = s.count, hot = s.id === "review";
      if (s.id === "agents") {
        var st = agentStatus();
        count = st === "working" || st === "waiting" || st === "done" ? 1 : 0;
        hot = st === "waiting" || st === "done";
      }
      var c = count ? '<span class="d-c' + (hot ? " hot" : "") + '">' + count + "</span>" : "";
      h += '<button class="d-it' + on + '" data-sec="' + s.id + '" style="--c:' + s.color + '"><span class="d-tile" style="--c:' + s.color + '">' + icon(s.icon, "ti") + "</span><span>" + s.title + "</span>" + c + "</button>";
    });
    h += '<div class="d-me">' + avatar("arivera") + '<div><b>Alex Rivera</b><small>@arivera</small></div></div></div>';
    return h;
  }

  function sectionById(id) {
    for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === id) return SECTIONS[i];
  }

  function listBar(title, count, extra) {
    return '<div class="d-bar"><div><b>' + title + "</b><small>" + count + '</small></div><span class="d-bar-acts">' + (extra || "") +
      '<button class="d-kbtn" data-palette aria-label="Open command palette">' + icon("search", "ti") + "<kbd>" + mod() + "K</kbd></button></span></div>";
  }

  function listColumn() {
    var s = sectionById(state.section);
    var refresh = '<button class="d-ibtn' + (state.refreshing ? " spin" : "") + '" data-refresh aria-label="Refresh">' + icon("refresh", "ti") + "</button>";
    if (state.section === "agents") return '<div class="d-list">' + listBar("Agents", "3 projects", '<button class="d-ibtn" data-new aria-label="New agent session">' + icon("plus", "ti") + "</button>") + agentList() + "</div>";
    var h = '<div class="d-list">' + listBar(s.title, listCount(), s.id === "projects" ? "" : refresh);
    if (s.list) {
      h += '<div class="d-seg">' + ["open", "closed", "all"].map(function (f) {
        return '<button data-filter="' + f + '" class="' + (state.filter === f ? "on" : "") + '">' + f.charAt(0).toUpperCase() + f.slice(1) + "</button>";
      }).join("") + "</div>";
      var ids = s.list.filter(function (id) {
        var st = PRS[id].state;
        return state.filter === "all" || (state.filter === "open" ? st !== "merged" : st === "merged");
      });
      if (!ids.length) h += '<div class="d-empty">Nothing here</div>';
      ids.forEach(function (id) { h += prRow(id); });
      h += '<div class="d-upd">Updated <span data-ago>' + agoText() + "</span></div>";
    } else if (state.section === "notifications") {
      NOTIFS.forEach(function (n) {
        var p = PRS[n.pr];
        var col = n.type === "fail" ? "var(--coral)" : "var(--violet)";
        h += '<button class="d-row' + (state.pr === n.pr && state.detail === "pr" ? " on" : "") + '" data-pr="' + n.pr + '"><span class="d-state" style="color:' + col + ';background:color-mix(in srgb,' + col + ' 16%,transparent)">' + icon(n.type === "fail" ? "x" : n.type === "merge" ? "merge" : "pr", "ti") + '</span><span class="d-rt"><b>' + esc(p.title) + "</b><small>" + p.repo + " #" + n.pr + " · " + n.text + '</small><small class="d-reason">' + n.reason + '</small></span><span class="d-dot"></span></button>';
      });
      h += '<div class="d-upd">Updated <span data-ago>' + agoText() + "</span></div>";
    } else if (state.section === "stacks") {
      Object.keys(STACKS).forEach(function (k) {
        var st = STACKS[k];
        h += '<div class="d-sub">' + st.repo + '</div><div class="d-stk"><div class="d-stk-h">' + icon("stack", "ti") + "<b>" + st.title + "</b><small>" + st.prs.length + " PRs</small></div>";
        st.prs.forEach(function (id) {
          var p = PRS[id];
          h += '<button class="d-stk-r' + (state.detail === "pr" && state.pr === id ? " on" : "") + '" data-pr="' + id + '"><i class="d-stk-dot" style="background:' + stateColor(p.state) + '"></i><span class="d-rt"><b>' + esc(p.title) + "</b><small>#" + id + " · " + p.state + "</small></span></button>";
        });
        h += "</div>";
      });
    } else if (state.section === "repos") {
      REPOS.forEach(function (r, i) {
        h += '<button class="d-row' + (state.detail === "repo" && state.repo === i ? " on" : "") + '" data-repo="' + i + '"><span class="d-tile sm" style="--c:#2dd4bf">' + icon("book", "ti") + '</span><span class="d-rt"><b>' + r[0] + "</b><small>" + r[3] + '</small><small><i class="d-lang" style="background:' + r[2] + '"></i>' + r[1] + " · ★ " + r[4] + "</small></span></button>";
      });
    } else if (state.section === "projects") {
      h += '<button class="d-row on"><span class="d-tile sm" style="--c:#6366f1">' + icon("board", "ti") + '</span><span class="d-rt"><b>Q4 roadmap</b><small>12 items · 3 columns</small></span></button>';
    }
    return h + "</div>";
  }

  function sessionRow(id, title, status, branch, child) {
    var s = STATUS[status];
    return '<button class="d-row d-ses' + (child ? " child" : "") + (state.session === id ? " on" : "") + '" data-ses="' + id + '"><span class="d-sdot' + (status === "working" ? " work" : "") + '" style="background:' + s[0] + '"></span><span class="d-rt"><b>' + title + "</b><small>" + s[1] + (branch ? ' · <i class="d-chip v">' + branch + "</i>" : "") + "</small></span></button>";
  }

  function agentList() {
    var h = '<div class="d-sub">' + icon("folder", "ti") + "web-app</div>";
    h += sessionRow("main", "Cancel stale searches", agentStatus(), "feat/search-debounce");
    h += sessionRow("saved", SESSIONS.saved.title, "sleeping", SESSIONS.saved.branch);
    h += sessionRow("params", SESSIONS.params.title, "sleeping", "", true);
    h += '<div class="d-sub">' + icon("folder", "ti") + "api</div>";
    h += sessionRow("token", SESSIONS.token.title, "sleeping", SESSIONS.token.branch);
    h += '<div class="d-sub">' + icon("folder", "ti") + 'ios<span class="d-sub-n">No sessions</span></div>';
    return h;
  }

  function listCount() {
    var s = sectionById(state.section);
    if (s.list) return s.list.length;
    if (state.section === "notifications") return NOTIFS.length;
    if (state.section === "repos") return REPOS.length;
    if (state.section === "stacks") return Object.keys(STACKS).length;
    return "";
  }

  function prRow(id) {
    var p = PRS[id];
    var on = (state.detail === "pr" && state.pr === id ? " on" : "") + (state.fresh === id && !state.freshDone ? " d-new" : "");
    return '<button class="d-row' + on + '" data-pr="' + id + '">' + stateBadge(p) + '<span class="d-rt"><b>' + esc(p.title) + "</b><small>" + p.repo + "#" + id + " · " + p.ago + "</small><small>" + avatar(p.author) + p.author + ' <i class="g">+' + p.add + '</i> <i class="r">−' + p.del + "</i></small></span></button>";
  }

  function checksBadge(p) {
    var fail = p.checks.filter(function (c) { return c[0] === "fail"; }).length;
    var run = p.checks.filter(function (c) { return c[0] === "run"; }).length;
    var ok = p.checks.length - fail - run;
    if (fail) return ['<em class="r">' + fail + " failed</em>"];
    if (run) return ['<em class="a">' + ok + "/" + p.checks.length + "</em>"];
    return ['<em class="g">' + ok + "/" + p.checks.length + "</em>"];
  }

  function detail() {
    var back = '<button class="d-back" data-back>' + icon("back", "ti") + "Back</button>";
    if (state.section === "agents") return '<div class="d-det">' + back + agentView() + "</div>";
    if (state.detail === "repo") return '<div class="d-det">' + back + repoView() + "</div>";
    if (state.section === "projects") return '<div class="d-det">' + back + boardView() + "</div>";
    if (state.detail !== "pr") return '<div class="d-det d-placeholder"><span class="d-tile lg" style="--c:var(--violet)">' + icon("pr", "ti") + "</span><p>Select a pull request</p></div>";
    var p = PRS[state.pr];
    var col = stateColor(p.state);
    var h = '<div class="d-det">' + back + '<div class="d-head"><h3>' + esc(p.title) + " <span>#" + state.pr + '</span></h3><div class="d-meta"><span class="d-pill" style="background:' + col + '">' + icon(stateIcon(p.state), "ti") + p.state.charAt(0).toUpperCase() + p.state.slice(1) + "</span>" + avatar(p.author) + "<b>" + p.author + '</b><i class="d-chip s">' + p.base + '</i><span class="d-arrow">←</span><i class="d-chip v">' + p.head + '</i><i class="g">+' + p.add + '</i><i class="r">−' + p.del + '</i><span class="d-ago">' + p.ago + " ago</span></div>";
    if (p.rerequest && !state.rerqHidden) {
      h += state.requested
        ? '<div class="d-rerq done">' + icon("check", "ti") + "<b>Requested</b><span>· Review re-requested from @" + p.rerequest.who + "</span></div>"
        : '<div class="d-rerq"><span>' + icon("commit", "ti") + "You pushed " + p.rerequest.n + (p.rerequest.n === 1 ? " commit" : " commits") + " after @" + p.rerequest.who + " reviewed</span><button data-rerq>Re-request review</button></div>";
    }
    if (p.review && !p.fixed) h += '<div class="d-fix"><span>' + icon("chat", "ti") + '1 unresolved comment</span><button data-fix>' + icon("spark", "ti") + "Fix with agent</button></div>";
    h += "</div>";
    var tabs = [["conversation", "Conversation", "chat", p.review && !p.fixed ? "<em>1</em>" : ""], ["commits", "Commits", "commit", "<em>" + p.commits.length + "</em>"], ["checks", "Checks", "check", checksBadge(p)[0]], ["files", "Files changed", "file", "<em>" + p.files.length + "</em>"]];
    if (p.stack) tabs.push(["stack", "Stack", "stack", "<em>" + STACKS[p.stack].prs.length + "</em>"]);
    if (p.jira) tabs.push(["jira", "Jira", "ticket", "<em>" + p.jira.key + "</em>"]);
    if (!tabs.some(function (t) { return t[0] === state.tab; })) state.tab = "conversation";
    h += '<div class="d-tabs">' + tabs.map(function (t) {
      return '<button data-tab="' + t[0] + '" class="' + (state.tab === t[0] ? "on" : "") + '">' + icon(t[2], "ti") + t[1] + t[3] + "</button>";
    }).join("") + '<span class="d-ul"></span></div><div class="d-body">' + tabBody(p) + "</div></div>";
    return h;
  }

  function tabBody(p) {
    if (state.tab === "conversation") {
      var h = '<div class="d-conv"><div class="d-card"><div class="d-ch">' + avatar(p.author) + "<b>" + p.author + "</b> · description · " + p.ago + ' ago</div><div class="d-cb">' + p.body + "</div></div>";
      if (p.review) {
        h += '<div class="d-card"><div class="d-ch">' + avatar(p.review.who) + "<b>" + p.review.who + '</b> · <span class="r">requested changes</span>' + (p.fixed ? '<span class="d-res">' + icon("check", "ti") + "Resolved</span>" : "") + '</div><div class="d-cb"><div class="d-tpath">' + p.review.file + ":" + p.review.line + "</div>" + esc(p.review.text) +
          (p.fixed ? "" : '<div class="d-acts"><button>Reply</button><button>Resolve</button><button class="d-hot" data-fix>' + icon("spark", "ti") + "Fix with agent</button></div>") + "</div></div>";
      }
      return h + '<div class="d-composer">Comment (Markdown) — ' + sendKey() + ' to send<span>Comment</span></div></div>';
    }
    if (state.tab === "commits") {
      return '<div class="d-plain">' + p.commits.map(function (c, i) {
        return '<div class="d-line">' + icon("commit", "ti dim") + "<b>" + esc(c[0]) + "</b><small>" + avatar(c[1]) + c[1] + " · " + (c[2] === "now" ? "now" : c[2] + " ago") + '</small><code>' + (c[3] || ["a3f9c21", "7b1e044", "c09d5af", "e4a7713"][i % 4]) + "</code></div>";
      }).join("") + "</div>";
    }
    if (state.tab === "checks") {
      return '<div class="d-plain">' + p.checks.map(function (c) {
        var ic = c[0] === "ok" ? icon("check", "ti g") : c[0] === "fail" ? icon("x", "ti r") : '<span class="d-spin sky"></span>';
        return '<div class="d-line">' + ic + "<b>" + c[1] + "</b><small>" + c[2] + "</small></div>";
      }).join("") + "</div>";
    }
    if (state.tab === "stack") return stackView(p);
    if (state.tab === "jira") return jiraView(p);
    return filesView(p);
  }

  function viewedKey(f) {
    return state.pr + ":" + f.path;
  }

  function filesView(p) {
    var idx = Math.min(state.file, p.files.length - 1);
    var f = p.files[idx];
    var done = p.files.filter(function (x) { return state.viewed[viewedKey(x)]; }).length;
    var h = '<div class="d-files' + (state.diffMode === "split" ? " wide" : "") + '"><div class="d-flist"><div class="d-ff">' + done + " of " + p.files.length + " viewed</div>";
    p.files.forEach(function (file, i) {
      var parts = file.path.split("/");
      var seen = state.viewed[viewedKey(file)];
      h += '<button class="d-file' + (file === f ? " on" : "") + (seen ? " seen" : "") + '" data-file="' + i + '"><i class="' + (file.st === "A" ? "g" : "a") + '">' + file.st + "</i><span><b>" + parts.pop() + "</b><small>" + parts.join("/") + "</small></span>" + (seen ? icon("check", "ti g") : "") + "</button>";
    });
    h += '<div class="d-keys"><kbd>J</kbd><kbd>K</kbd> files <kbd>V</kbd> viewed</div></div>';
    var seen = state.viewed[viewedKey(f)];
    h += '<div class="d-diff"><div class="d-fh"><span class="d-fp">' + f.path + '</span><i class="g">+' + f.add + '</i><i class="r">−' + f.del + "</i>" +
      '<span class="d-mode"><button data-mode="unified" class="' + (state.diffMode === "unified" ? "on" : "") + '" aria-label="Unified diff">' + icon("unified", "ti") + '</button><button data-mode="split" class="' + (state.diffMode === "split" ? "on" : "") + '" aria-label="Split diff">' + icon("split", "ti") + "</button></span>" +
      '<button class="d-viewed' + (seen ? " on" : "") + '" data-viewed><i>' + (seen ? icon("check", "ti") : "") + "</i>Viewed</button></div>";
    if (seen) return h + '<div class="d-collapsed">Marked as viewed. ' + (idx < p.files.length - 1 ? "Press <kbd>J</kbd> for the next file." : "That was the last file.") + "</div></div></div>";
    h += state.diffMode === "split" ? splitDiff(f.lines) : f.lines.map(unifiedLine).join("");
    return h + "</div></div>";
  }

  function unifiedLine(l) {
    return '<div class="d-ln ' + l[0] + '"><span>' + l[1] + "</span><span>" + l[2] + "</span><span>" + (l[0] === "a" ? "+" : l[0] === "d" ? "−" : "") + "</span><span>" + (l[0] === "h" ? esc(l[3]) : hl(l[3])) + "</span></div>";
  }

  function splitDiff(lines) {
    var rows = [], dels = [], adds = [];
    function flush() {
      for (var i = 0; i < Math.max(dels.length, adds.length); i++) rows.push([dels[i] || null, adds[i] || null]);
      dels = []; adds = [];
    }
    lines.forEach(function (l) {
      if (l[0] === "d") dels.push(l);
      else if (l[0] === "a") adds.push(l);
      else { flush(); rows.push(l[0] === "h" ? l : [l, l]); }
    });
    flush();
    function cell(l, side) {
      if (!l) return '<span class="n se"></span><span class="c se"></span>';
      var cls = l[0] ? " s" + l[0] : "";
      return '<span class="n' + cls + '">' + (side ? l[2] : l[1]) + '</span><span class="c' + cls + '">' + hl(l[3]) + "</span>";
    }
    return rows.map(function (r) {
      if (r[0] === "h") return '<div class="d-sp sh"><span>' + esc(r[3]) + "</span></div>";
      return '<div class="d-sp">' + cell(r[0], 0) + cell(r[1], 1) + "</div>";
    }).join("");
  }

  function stackView(p) {
    var st = STACKS[p.stack];
    var h = '<div class="d-conv"><div class="d-card"><div class="d-ch">' + icon("stack", "ti") + "<b>" + st.title + "</b> · " + st.repo + '</div><div class="d-tree2"><div class="d-tn base"><i class="d-chip s">main</i></div>';
    st.prs.forEach(function (id) {
      var q = PRS[id];
      h += '<button class="d-tn' + (id === state.pr ? " cur" : "") + '" data-pr="' + id + '" data-keep-tab><i class="d-stk-dot" style="background:' + stateColor(q.state) + '"></i><b>' + esc(q.title) + "</b><small>#" + id + " · " + q.state + "</small>" + (id === state.pr ? '<span class="d-here">This PR</span>' : "") + "</button>";
    });
    h += '</div></div><div class="d-card"><div class="d-ch">' + icon("note", "ti") + '<b>Stack notes</b><span class="d-ch-r">Only on this Mac</span></div><div class="d-cb d-notes">';
    h += '<div class="d-note"><span class="d-tile sm" style="--c:#ee6f5f">' + icon("term", "ti") + "</span><div><b>Agent</b><small>2h ago</small><p>#485 reuses <code>useDebounce</code>. Rebase it after this merges, no conflicts expected.</p></div></div>";
    if (p.fixed) h += '<div class="d-note new"><span class="d-tile sm" style="--c:#ee6f5f">' + icon("term", "ti") + "</span><div><b>Agent</b><small>now</small><p>Stale requests are aborted in <code>useSearch</code>. #485 picks this up on rebase.</p></div></div>";
    return h + "</div></div></div>";
  }

  function jiraView(p) {
    var j = p.jira;
    var cur = JIRA_FLOW.filter(function (s) { return s[0] === state.jira; })[0];
    var h = '<div class="d-conv"><div class="d-card d-jira"><div class="d-jp">' + icon("stack", "ti") + j.parent + '</div><div class="d-jh"><span class="d-tile sm" style="--c:#5bb8ec">' + icon("ticket", "ti") + "</span><div><small>" + j.key + "</small><b>" + j.title + '</b></div><span class="d-jst" style="--c:' + cur[1] + '">' + state.jira + "</span></div>";
    h += '<div class="d-jm"><i class="d-chip s">' + j.type + '</i><i class="d-chip a">' + j.prio + "</i><span>" + avatar(j.who) + j.who + "</span></div>";
    h += '<div class="d-jt"><small>Move to</small>' + JIRA_FLOW.map(function (s) {
      return '<button data-jira="' + s[0] + '" class="' + (s[0] === state.jira ? "on" : "") + '" style="--c:' + s[1] + '">' + s[0] + "</button>";
    }).join("") + "</div></div></div>";
    return h;
  }

  function repoView() {
    var r = REPOS[state.repo];
    return '<div class="d-repo"><div class="d-card d-rhead"><span class="d-tile md" style="--c:#2dd4bf">' + icon("book", "ti") + "</span><div><b>" + r[0] + "</b><small>" + r[3] + '</small><div class="d-meta"><i class="d-chip a">★ ' + r[4] + '</i><i class="d-chip s">main</i></div></div></div><div class="d-tree">' +
      ["src", "tests", ".github"].map(function (d) { return '<div class="d-tr">' + icon("folder", "ti s") + d + "</div>"; }).join("") +
      ["README.md", "package.json", "tsconfig.json"].map(function (d) { return '<div class="d-tr">' + icon("file", "ti dim") + d + "</div>"; }).join("") +
      '</div><div class="d-card d-readme"><h4>' + r[0].split("/")[1] + "</h4><p>" + r[3] + ". Run <code>make dev</code> to start it locally.</p></div></div>";
  }

  function boardView() {
    var cols = [["Todo", "#94a3b8", ["Saved searches", "Offline mode"]], ["In progress", "#5bb8ec", ["Search debounce #482", "Dark settings #479"]], ["Done", "#9d8cf0", ["Empty list crash #77"]]];
    return '<div class="d-board">' + cols.map(function (c) {
      return '<div class="d-col"><div class="d-colh" style="border-top-color:' + c[1] + '">' + c[0] + "<em>" + c[2].length + "</em></div>" + c[2].map(function (t) { return '<div class="d-item">' + t + "</div>"; }).join("") + "</div>";
    }).join("") + "</div>";
  }

  var KINDS = { cmd: ["term", "#5bb8ec", "ran", "command", "commands"], read: ["file", "#9d8cf0", "read", "file", "files"], edit: ["edit", "#ee6f5f", "edited", "file", "files"], search: ["search", "#2dd4bf", "searched", "pattern", "patterns"] };
  function groupLabel(steps) {
    var counts = {}, order = [];
    steps.forEach(function (s) { if (!counts[s[0]]) { counts[s[0]] = 0; order.push(s[0]); } counts[s[0]]++; });
    var t = order.map(function (k) { var d = KINDS[k]; return d[2] + " " + counts[k] + " " + (counts[k] === 1 ? d[3] : d[4]); }).join(", ");
    return t.charAt(0).toUpperCase() + t.slice(1);
  }

  function currentSession() {
    if (state.session === "main") return state.chat;
    return SESSIONS[state.session] || null;
  }

  function agentView() {
    if (state.session === "new") return welcomeView();
    var main = state.session === "main";
    var c = currentSession() || { items: [] };
    var title = main ? "Cancel stale searches" : c.title;
    var branch = main ? "feat/search-debounce" : c.branch;
    var insp = state.inspector && main;
    var h = '<div class="d-chatw' + (insp ? "" : " noinsp") + '"><div class="d-chat"><div class="d-ctab"><span class="d-ct">' + esc(title) + '</span><i class="d-chip v d-br">' + icon("branch", "ti") + "<span>" + branch + '</span></i><span class="d-cmodel">Opus</span>' +
      (main ? '<button class="d-ibtn d-inspbtn' + (insp ? " on" : "") + '" data-insp aria-label="Toggle inspector">' + icon("panel", "ti") + "</button>" : "") + '</div><div class="d-msgs" id="d-msgs">';
    if (main && !c.items.length) h += '<div class="d-welcome"><span class="d-tile lg" style="--c:var(--coral)">' + icon("term", "ti") + '</span><b>Agents</b><p>Open a PR and press <em>Fix with agent</em>, or start here.</p><button class="d-start" data-fix>' + icon("spark", "ti") + "Fix review on #482</button></div>";
    if (!main) h += '<div class="d-sleep">' + icon("moon", "ti") + "Sleeping. A new message resumes the session.</div>";
    c.items.forEach(function (it, i) { h += chatItem(it, main && i === c.fresh); });
    if (c.busy) h += '<div class="d-working"><span class="d-spin"></span>Working…</div>';
    h += "</div>" + composer() + "</div>";
    if (insp) h += inspector();
    return h + "</div>";
  }

  function welcomeView() {
    return '<div class="d-chat"><div class="d-ctab"><span class="d-ct">New session <small>web-app</small></span><i class="d-chip v d-br">' + icon("branch", "ti") + '<span>main</span></i><span class="d-cmodel">Opus</span></div><div class="d-msgs" id="d-msgs"><div class="d-welcome"><span class="d-tile lg" style="--c:var(--coral)">' + icon("term", "ti") + "</span><b>New agent session</b><p>Working in <em>web-app</em>. Describe a task, or pick up a review.</p><button class=\"d-start\" data-fix>" + icon("spark", "ti") + "Fix review on #482</button></div></div>" + composer() + "</div>";
  }

  function composer() {
    return '<form class="d-ccomp" data-compose><input placeholder="Describe a task or ask a question…" aria-label="Message"><div class="d-crow"><span>Accept edits ▾</span><span>Opus ▾</span><span>effort ▾</span><span class="d-ring"></span><button type="submit" aria-label="Send">' + icon("send", "ti") + "</button></div></form>";
  }

  function chatItem(step, fresh) {
    var n = fresh ? " new" : "";
    if (step.k === "user") return '<div class="d-um' + n + '">' + step.text + "</div>";
    if (step.k === "text") return '<div class="d-ans' + n + '">' + step.text + "</div>";
    if (step.k === "denied") return '<div class="d-ans dim' + n + '">Skipped the tests. Tell me what to do instead.</div>';
    if (step.k === "group") return groupItem(step, n);
    if (step.k === "prcard") {
      var p = PRS[step.pr];
      return '<button class="d-prc' + n + '" data-pr="' + step.pr + '">' + stateBadge(p) + '<span class="d-rt"><b>' + esc(p.title) + "</b><small>" + p.repo + "#" + step.pr + " · " + p.state + "</small></span>" + icon("chev", "ti dim") + "</button>";
    }
    if (step.k === "perm") return '<div class="d-perm' + n + '"><small>Claude wants to run a command</small><code>npm test -- search</code><div class="d-pacts"><button data-allow>Allow</button><button data-deny>Deny</button><kbd>' + sendKey() + "</kbd></div></div>";
    if (step.k === "ship") return '<div class="d-ship' + n + '"><span>' + icon("branch", "ti") + '1 file changed on <i class="d-chip v">feat/search-debounce</i></span><button data-ship>' + icon("push", "ti") + "Commit and push</button></div>";
    if (step.k === "shipped") return '<div class="d-ship done' + n + '"><span>' + icon("check", "ti g") + '<b>Pushed b81c0de</b> to #482 · checks running</span><button data-pr="482" data-tab-go="commits">Open PR</button></div>';
    return "";
  }

  function groupItem(step, n) {
    var open = state.open[step.id] !== undefined ? state.open[step.id] : !!step.open;
    var kinds = [];
    step.steps.forEach(function (s) { if (kinds.indexOf(s[0]) < 0) kinds.push(s[0]); });
    var h = '<div class="d-grp' + (open ? " open" : "") + n + '"><button class="d-gh" data-grp="' + step.id + '" aria-expanded="' + open + '">' + icon("chev", "ti d-gchev") +
      '<span class="d-gic">' + kinds.map(function (k) { return '<i style="color:' + KINDS[k][1] + '">' + icon(KINDS[k][0], "ti") + "</i>"; }).join("") + "</span><b>" + groupLabel(step.steps) + "</b>" +
      (step.edit ? '<span class="d-st"><i class="g">+3</i> <i class="r">−1</i></span>' : "") + "</button>";
    if (open) {
      h += '<div class="d-gsteps">' + step.steps.map(function (s) {
        return '<div class="d-gs"><span class="d-ok">' + icon("check", "ti") + "</span>" + esc(s[1]) + "</div>";
      }).join("");
      if (step.edit) {
        h += '<div class="d-gdiff">' + [
          ["a", "", "24", "    const ctrl = new AbortController()"],
          ["d", "25", "", "    fetchResults(debounced)"],
          ["a", "", "25", "    fetchResults(debounced, ctrl.signal)"],
          ["a", "", "29", "    return () => ctrl.abort()"]
        ].map(unifiedLine).join("") + "</div>";
      }
      if (step.out) h += "<pre>" + esc(step.out) + "</pre>";
      h += "</div>";
    }
    return h + "</div>";
  }

  function inspector() {
    var c = state.chat || { items: [] };
    var edited = c.items.some(function (it) { return it.edit; }) && !c.shipped;
    var taskDone = c.items.some(function (it) { return it.task; });
    var taskRun = c.busy && SCRIPT[c.step] && SCRIPT[c.step].task;
    var tabs = [["changes", "Changes", edited ? 1 : 0], ["tasks", "Tasks", taskRun ? 1 : 0], ["pr", "PR", 0]];
    var h = '<div class="d-insp"><div class="d-itabs">' + tabs.map(function (t) {
      return '<button data-itab="' + t[0] + '" class="' + (state.itab === t[0] ? "on" : "") + '">' + t[1] + (t[2] ? "<em>" + t[2] + "</em>" : "") + "</button>";
    }).join("") + '</div><div class="d-ibody">';
    if (state.itab === "changes") {
      if (edited) h += '<div class="d-ifile">' + icon("file", "ti dim") + '<span><b>useSearch.ts</b><small>src/search</small></span><i class="a">M</i></div><div class="d-ihint"><i class="g">+3</i> <i class="r">−1</i> · not committed</div>';
      else if (c.shipped) h += '<div class="d-iempty">' + icon("check", "ti g") + "Working tree clean<small>Pushed b81c0de to feat/search-debounce</small></div>";
      else h += '<div class="d-iempty">No changes yet<small>Edits the agent makes show up here.</small></div>';
    } else if (state.itab === "tasks") {
      if (taskRun) h += '<div class="d-task"><span class="d-spin sky"></span><span><b>npm test -- search</b><small>Running…</small></span></div>';
      else if (taskDone) h += '<div class="d-task"><span class="d-ok">' + icon("check", "ti") + "</span><span><b>npm test -- search</b><small>12 passed · 2.4s</small></span></div>";
      else h += '<div class="d-iempty">No tasks yet<small>Commands and sub-agents appear here while they run.</small></div>';
    } else {
      var p = PRS[482];
      h += '<button class="d-prc" data-pr="482">' + stateBadge(p) + '<span class="d-rt"><b>' + esc(p.title) + "</b><small>#482 · " + (c.shipped ? "checks running" : "4/4 checks passed") + "</small></span></button>";
    }
    return h + "</div></div>";
  }

  var timer = null;
  function runChat() {
    var c = state.chat;
    if (!c || c.waiting) return;
    if (c.step >= SCRIPT.length) { c.busy = false; render(); return; }
    c.busy = true;
    render();
    var step = SCRIPT[c.step];
    timer = setTimeout(function () {
      c.items.push(step);
      c.fresh = c.items.length - 1;
      c.step++;
      if (step.k === "perm") { c.waiting = true; c.busy = false; c.seen = false; notify("Agent needs you", "Allow npm test -- search?"); return; }
      if (step.k === "ship") { c.busy = false; c.seen = state.section === "agents" && state.session === "main"; notify("Agent finished", "Cancel stale searches · 12 tests pass"); return; }
      render();
      runChat();
    }, step.k === "user" ? 250 : step.task ? 1600 : 900);
  }

  function notify(title, text) {
    if (state.section !== "agents" || state.session !== "main") {
      state.toast = { title: title, text: text };
      clearTimeout(notify.t);
      notify.t = setTimeout(function () { state.toast = null; render(); }, 6000);
    }
    render();
  }

  function startFix() {
    clearTimeout(timer);
    state.section = "agents";
    state.session = "main";
    state.chat = { step: 0, items: [], busy: false, waiting: false, seen: true };
    state.open = {};
    state.itab = "changes";
    state.detailOpen = true;
    state.toast = null;
    render();
    runChat();
  }

  function ship() {
    var c = state.chat;
    c.items.pop();
    c.items.push({ k: "shipped" });
    c.fresh = c.items.length - 1;
    c.shipped = true;
    var p = PRS[482];
    p.fixed = true;
    p.commits.push(["Abort stale search requests", "arivera", "now", "b81c0de"]);
    p.checks = p.checks.map(function (x) { return x[1] === "lint" ? x : ["run", x[1], "running"]; });
    state.requested = false;
    state.rerqHidden = false;
    p.rerequest.n = 1;
    render();
    setTimeout(function () {
      p.checks = p.checks.map(function (x) { return x[0] === "run" ? ["ok", x[1], x[1] === "e2e / chrome" ? "3m 31s" : "52s"] : x; });
      render();
    }, 7000);
  }

  function selectSection(id) {
    state.section = id;
    state.detailOpen = false;
    var s = sectionById(id);
    if (s.list) { state.filter = "open"; state.detail = s.list.indexOf(state.pr) >= 0 && state.detail === "pr" ? "pr" : null; }
    if (id === "repos") state.detail = null;
    if (id === "agents" && state.session === "main" && state.chat && !state.chat.busy) state.chat.seen = true;
    if (id === "agents") state.toast = null;
    render();
  }

  function openPR(id, tab) {
    state.pr = id; state.detail = "pr"; state.tab = tab || "conversation"; state.file = 0; state.detailOpen = true;
    var s = sectionById(state.section);
    var inStack = state.section === "stacks" && PRS[id].stack;
    if (!inStack && state.section !== "notifications" && !(s.list && s.list.indexOf(id) >= 0)) {
      var owner = SECTIONS.filter(function (x) { return x.list && x.list.indexOf(id) >= 0; })[0];
      state.section = owner ? owner.id : PRS[id].stack ? "stacks" : "review";
      state.filter = PRS[id].state === "merged" ? "all" : "open";
    }
    render();
  }

  function openSession(id) {
    state.section = "agents";
    state.session = id;
    state.detailOpen = true;
    if (id === "main" && state.chat && !state.chat.busy) state.chat.seen = true;
    state.toast = null;
    render();
  }

  function refresh() {
    state.updated = Date.now();
    state.refreshing = true;
    lastListKey = null;
    render();
    setTimeout(function () { state.refreshing = false; render(); }, 700);
  }

  function commands() {
    var list = [];
    SECTIONS.forEach(function (s) {
      if (!s.id) return;
      list.push({ g: "Go to", ic: s.icon, col: s.color, t: s.title, run: function () { selectSection(s.id); } });
    });
    [482, 485, 480, 479, 213, 91, 77, 58].forEach(function (id) {
      var p = PRS[id];
      if (id === 91 && sectionById("review").list.indexOf(91) < 0) return;
      list.push({ g: "Pull requests", ic: stateIcon(p.state), col: stateColor(p.state), t: p.title, d: p.repo + "#" + id, run: function () { openPR(id); } });
    });
    list.push({ g: "Actions", ic: "spark", col: "#ee6f5f", t: "Fix review on #482 with agent", run: startFix });
    list.push({ g: "Actions", ic: "plus", col: "#ee6f5f", t: "New Agent Session", d: "Agents", k: mod() + "N", run: function () { openSession("new"); } });
    list.push({ g: "Actions", ic: state.diffMode === "split" ? "unified" : "split", col: "#5bb8ec", t: state.diffMode === "split" ? "Show unified diff" : "Show split diff", run: function () { state.diffMode = state.diffMode === "split" ? "unified" : "split"; openPR(state.pr, "files"); } });
    list.push({ g: "Actions", ic: "refresh", col: "#2dd4bf", t: "Refresh", k: mod() + "R", run: refresh });
    return list;
  }

  function filtered() {
    var q = state.palette.q.toLowerCase().trim();
    return commands().filter(function (c) {
      return !q || (c.t + " " + (c.d || "") + " " + c.g).toLowerCase().indexOf(q) >= 0;
    });
  }

  function paletteList() {
    var items = filtered(), g = null, h = "";
    if (!items.length) return '<div class="d-empty">No matches</div>';
    state.palette.sel = Math.max(0, Math.min(state.palette.sel, items.length - 1));
    items.forEach(function (c, i) {
      if (c.g !== g) { g = c.g; h += '<div class="d-pal-g">' + g + "</div>"; }
      h += '<button class="d-pal-it' + (i === state.palette.sel ? " on" : "") + '" data-cmd="' + i + '"><span class="d-tile sm" style="--c:' + c.col + '">' + icon(c.ic, "ti") + "</span><span>" + esc(c.t) + "</span>" + (c.d ? "<small>" + c.d + "</small>" : "") + (c.k ? "<kbd>" + c.k + "</kbd>" : "") + "</button>";
    });
    return h;
  }

  function paletteView() {
    if (!state.palette) return "";
    return '<div class="d-pal-bg" data-pal-bg><div class="d-pal" role="dialog" aria-label="Command palette"><div class="d-pal-in">' + icon("search", "ti dim") + '<input data-pal-q placeholder="Go to, open a pull request or run a command" aria-label="Search commands" value="' + esc(state.palette.q).replace(/"/g, "&quot;") + '"><kbd>esc</kbd></div><div class="d-pal-list">' + paletteList() + "</div></div></div>";
  }

  function refreshPalette() {
    var list = root.querySelector(".d-pal-list");
    if (list) list.innerHTML = paletteList();
    var on = list && list.querySelector(".on");
    if (on && on.scrollIntoView) on.scrollIntoView({ block: "nearest" });
  }

  function openPalette() {
    state.palette = { q: "", sel: 0 };
    render();
  }

  function closePalette() {
    state.palette = null;
    render();
  }

  function runCommand(i) {
    var c = filtered()[i];
    state.palette = null;
    if (c) c.run(); else render();
  }

  function toastView() {
    if (!state.toast) return "";
    return '<button class="d-toast" data-ses="main"><span class="d-tile sm" style="--c:#ee6f5f">' + icon("term", "ti") + "</span><span><b>" + state.toast.title + "</b><small>" + esc(state.toast.text) + "</small></span></button>";
  }

  var lastDetailKey = null, lastTabKey = null, lastListKey = null;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function agoText() {
    var s = Math.max(0, Math.round((Date.now() - state.updated) / 1000));
    return s < 10 ? "just now" : s < 60 ? Math.floor(s / 5) * 5 + "s ago" : Math.floor(s / 60) + "m ago";
  }

  function render() {
    var msgs = document.getElementById("d-msgs");
    var pinned = !msgs || msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 40;
    var sessionKey = state.section + "|" + state.session;
    root.className = "demo os-" + platform() + (state.detailOpen ? " show-detail" : "");
    root.innerHTML = windowBar() + sidebar() + listColumn() + detail() + toastView() + paletteView();
    var listKey = state.section + "|" + state.filter;
    if (listKey !== lastListKey) {
      Array.prototype.slice.call(root.querySelectorAll(".d-list .d-row"), 0, 12).forEach(function (r, i) {
        r.style.animationDelay = (reduced ? 0 : i * 70) + "ms";
        r.classList.add("d-in");
      });
      lastListKey = listKey;
    }
    if (state.fresh && !state.freshDone && root.querySelector(".d-new")) state.freshDone = true;
    var detailKey = [state.section, state.detail, state.pr, state.repo, state.session].join("|");
    var tabKey = detailKey + "|" + state.tab + "|" + state.file + "|" + state.diffMode;
    var det = root.querySelector(".d-det"), body = root.querySelector(".d-body");
    if (det && detailKey !== lastDetailKey && lastDetailKey !== null) det.classList.add("enter");
    else if (body && tabKey !== lastTabKey && lastTabKey !== null) body.classList.add("enter");
    lastDetailKey = detailKey;
    lastTabKey = tabKey;
    msgs = document.getElementById("d-msgs");
    if (msgs && (pinned || sessionKey !== render.session)) msgs.scrollTop = msgs.scrollHeight;
    render.session = sessionKey;
    var ul = root.querySelector(".d-ul"), on = root.querySelector(".d-tabs .on");
    if (ul && on) { ul.style.width = on.offsetWidth + "px"; ul.style.transform = "translateX(" + on.offsetLeft + "px)"; }
    var q = root.querySelector("[data-pal-q]");
    if (q) { q.focus({ preventScroll: true }); q.setSelectionRange(q.value.length, q.value.length); }
  }

  root.addEventListener("click", function (e) {
    if (e.target.hasAttribute && e.target.hasAttribute("data-pal-bg")) { closePalette(); return; }
    var t = e.target.closest("button");
    if (!t || !root.contains(t)) return;
    var d = t.dataset;
    if (d.cmd) runCommand(+d.cmd);
    else if (t.hasAttribute("data-palette")) openPalette();
    else if (d.sec) selectSection(d.sec);
    else if (d.ses) openSession(d.ses);
    else if (d.pr) {
      var keep = t.hasAttribute("data-keep-tab") ? state.tab : d.tabGo;
      openPR(+d.pr, keep);
    }
    else if (d.repo) { state.repo = +d.repo; state.detail = "repo"; state.detailOpen = true; render(); }
    else if (d.filter) { state.filter = d.filter; render(); }
    else if (d.tab) { state.tab = d.tab; render(); }
    else if (d.file) { state.file = +d.file; render(); }
    else if (d.mode) { state.diffMode = d.mode; render(); }
    else if (t.hasAttribute("data-viewed")) toggleViewed();
    else if (d.jira) { state.jira = d.jira; render(); }
    else if (d.grp) { var g = root.querySelector('[data-grp="' + d.grp + '"]'); state.open[d.grp] = g.getAttribute("aria-expanded") !== "true"; render(); }
    else if (d.itab) { state.itab = d.itab; render(); }
    else if (t.hasAttribute("data-insp")) { state.inspector = !state.inspector; render(); }
    else if (t.hasAttribute("data-new")) openSession("new");
    else if (t.hasAttribute("data-refresh")) refresh();
    else if (t.hasAttribute("data-ship")) ship();
    else if (t.hasAttribute("data-rerq")) {
      state.requested = true; render();
      setTimeout(function () { state.rerqHidden = true; render(); }, 2500);
    }
    else if (t.hasAttribute("data-fix")) startFix();
    else if (t.hasAttribute("data-back")) { state.detailOpen = false; render(); }
    else if (t.hasAttribute("data-allow") || t.hasAttribute("data-deny")) {
      var c = state.chat;
      c.waiting = false;
      c.items.pop();
      if (t.hasAttribute("data-deny")) { c.items.push({ k: "denied" }); c.fresh = c.items.length - 1; c.step = SCRIPT.length; c.busy = false; render(); return; }
      runChat();
    }
  });

  root.addEventListener("input", function (e) {
    if (!e.target.hasAttribute("data-pal-q") || !state.palette) return;
    state.palette.q = e.target.value;
    state.palette.sel = 0;
    refreshPalette();
  });

  root.addEventListener("submit", function (e) {
    e.preventDefault();
    var input = e.target.querySelector("input");
    var text = (input.value || "").trim();
    if (!text) return;
    var reply = { k: "text", text: "This is a live demo with a scripted session. Download PullYard to run agents on your own repositories." };
    if (state.session === "main" || state.session === "new") {
      state.session = "main";
      if (!state.chat) state.chat = { step: SCRIPT.length, items: [], seen: true };
      state.chat.items.push({ k: "user", text: esc(text) }, reply);
      state.chat.fresh = state.chat.items.length - 1;
    } else {
      SESSIONS[state.session].items.push({ k: "user", text: esc(text) }, reply);
    }
    render();
  });

  function toggleViewed() {
    var p = PRS[state.pr];
    var f = p.files[Math.min(state.file, p.files.length - 1)];
    var k = viewedKey(f);
    state.viewed[k] = !state.viewed[k];
    if (state.viewed[k] && state.file < p.files.length - 1) state.file++;
    render();
  }

  var hovering = false;
  root.addEventListener("pointerenter", function () { hovering = true; });
  root.addEventListener("pointerleave", function () { hovering = false; });

  document.addEventListener("keydown", function (e) {
    if (!hovering && !root.contains(document.activeElement)) return;
    var k = (e.key || "").toLowerCase();
    if (state.palette) {
      if (k === "escape") { e.preventDefault(); closePalette(); }
      else if (k === "arrowdown" || k === "arrowup") {
        e.preventDefault();
        state.palette.sel += k === "arrowdown" ? 1 : -1;
        refreshPalette();
      } else if (k === "enter") { e.preventDefault(); runCommand(state.palette.sel); }
      return;
    }
    if ((e.metaKey || e.ctrlKey) && k === "k") { e.preventDefault(); openPalette(); return; }
    var typing = /input|textarea/i.test((document.activeElement || {}).tagName || "");
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (state.section === "agents" || state.detail !== "pr" || state.tab !== "files") return;
    var n = PRS[state.pr].files.length;
    if (k === "j" || k === "k") { state.file = Math.max(0, Math.min(n - 1, state.file + (k === "j" ? 1 : -1))); render(); }
    else if (k === "v") toggleViewed();
  });

  setInterval(function () {
    var ago = root.querySelector("[data-ago]");
    if (ago) ago.textContent = agoText();
  }, 5000);

  setTimeout(function () {
    var review = sectionById("review");
    if (review.list.indexOf(91) >= 0) return;
    review.list.unshift(91);
    review.count += 1;
    state.fresh = 91;
    state.freshDone = false;
    state.updated = Date.now();
    if (state.section === "review" && !state.palette) render();
  }, 6000);

  document.addEventListener("platformchange", render);

  render();
})();
