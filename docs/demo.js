(function () {
  var root = document.getElementById("demo");
  if (!root) return;

  var reduceMQ = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  function reduced() { return reduceMQ.matches; }

  var ICONS = {
    sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16M5.5 8h1.5M5.5 11h1.5"/>',
    sidebarR: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16"/>',
    refresh: '<path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v5h-5"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
    bell: '<path d="M6 9a6 6 0 0 1 12 0c0 6 2.5 8 2.5 8h-17S6 15 6 9"/><path d="M10 20.5a2.2 2.2 0 0 0 4 0"/>',
    eye: '<path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    person: '<circle cx="12" cy="8" r="3.8"/><path d="M4.5 20c.8-4 4-6 7.5-6s6.7 2 7.5 6z"/>',
    personClock: '<circle cx="10" cy="8" r="3.6"/><path d="M3 20c.7-3.8 3.6-5.6 7-5.6 1.2 0 2.3.2 3.3.6"/><circle cx="18" cy="17" r="3.6"/><path d="M18 15.5V17l1 .8"/>',
    at: '<circle cx="12" cy="12" r="3.6"/><path d="M15.6 8.5v4.6a2.4 2.4 0 0 0 4.8 0V12a8.4 8.4 0 1 0-3.4 6.7"/>',
    checkBubble: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v9a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 3.5V17A2.5 2.5 0 0 1 4 14.5z"/><path d="m8.5 10 2.3 2.3 4.7-4.6"/>',
    folder: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h4l2 2h7A2.5 2.5 0 0 1 21 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16.5z"/>',
    folderPlus: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h4l2 2h7A2.5 2.5 0 0 1 21 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16.5z"/><path d="M15 10v6M12 13h6"/>',
    stack: '<path d="m12 3 8.5 4.5L12 12 3.5 7.5z"/><path d="m3.5 12 8.5 4.5 8.5-4.5"/><path d="m3.5 16.5 8.5 4.5 8.5-4.5"/>',
    issue: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="2.4" fill="currentColor"/>',
    book: '<path d="M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5z"/><path d="M5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3"/>',
    board: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M9 4.5v15M15 4.5v15"/>',
    terminal: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="m7 10 2.5 2L7 14M11.5 15h5"/>',
    pull: '<circle cx="6.5" cy="6" r="2.3"/><circle cx="6.5" cy="18" r="2.3"/><circle cx="17.5" cy="18" r="2.3"/><path d="M6.5 8.3v7.4M17.5 15.7V10a3 3 0 0 0-3-3h-4"/><path d="m12.5 4.8-2.2 2.2 2.2 2.2"/>',
    merge: '<path d="M8 21V12c0-3 2-5 4-6.5M12 5.5c2 1.5 4 3.5 4 6.5v9"/><path d="m9 6 3-3 3 3"/>',
    draft: '<circle cx="12" cy="12" r="8.5"/><path d="m9 15 .4-2.2 4.8-4.8 1.8 1.8-4.8 4.8z"/>',
    closed: '<circle cx="12" cy="12" r="8.5"/><path d="m9 9 6 6M15 9l-6 6"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    x: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
    dotted: '<circle cx="12" cy="12" r="7.5" stroke-dasharray="2.2 2.6"/>',
    seal: '<path d="m12 2.8 2.3 1.7 2.8-.2.9 2.7 2.3 1.6-.9 2.7.9 2.7-2.3 1.6-.9 2.7-2.8-.2L12 21.2l-2.3-1.7-2.8.2-.9-2.7-2.3-1.6.9-2.7-.9-2.7 2.3-1.6.9-2.7 2.8.2z" fill="currentColor" stroke="none"/><path d="m8.6 12 2.3 2.3 4.5-4.5" stroke="#fff"/>',
    exBubble: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v9a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 3.5V17A2.5 2.5 0 0 1 4 14.5z" fill="currentColor" stroke="none"/><path d="M12 6.5v4.5M12 13.6v.1" stroke="#fff"/>',
    bubble: '<path d="M4 6a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v7a3 3 0 0 1-3 3h-7l-4.5 4v-4A3 3 0 0 1 4 13z"/>',
    bubbles: '<path d="M3 5.5A2.5 2.5 0 0 1 5.5 3h8A2.5 2.5 0 0 1 16 5.5v5a2.5 2.5 0 0 1-2.5 2.5H8L5 15.5V13a2.5 2.5 0 0 1-2-2.5z"/><path d="M16 8h2.5A2.5 2.5 0 0 1 21 10.5v5a2.5 2.5 0 0 1-2 2.5v2.5L16 18h-4.5A2.5 2.5 0 0 1 9 15.5V15"/>',
    commits: '<circle cx="12" cy="12" r="3.2"/><path d="M3 12h5.8M15.2 12H21"/>',
    checklist: '<path d="m3.5 6.5 1.5 1.5 3-3M3.5 13.5l1.5 1.5 3-3"/><path d="M11 7h9.5M11 14h9.5M11 20h9.5"/>',
    doc: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
    link: '<path d="M10 13.5a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7L11.5 6.3"/><path d="M14 10.5a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.5-1.5"/>',
    arrowL: '<path d="M19 12H5M11 6l-6 6 6 6"/>',
    cycle: '<path d="M4.5 10a8 8 0 0 1 14.6-3.2M19.5 14a8 8 0 0 1-14.6 3.2"/><path d="M19.5 3.5v4h-4M4.5 20.5v-4h4"/>',
    wrench: '<path d="M14.5 6.5a4 4 0 0 0 5 5L20.8 13l-7.6 7.6a2.2 2.2 0 0 1-3.1-3.1L17.6 10l-1.5-1.3a4 4 0 0 0-1.6-2.2z"/><path d="m3.5 3.5 6 6M7.5 3.5l-4 4"/>',
    octagon: '<path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2z" fill="currentColor" stroke="none"/><path d="m9.5 9.5 5 5M14.5 9.5l-5 5" stroke="#fff"/>',
    plusminus: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="M12 6.5v6M9 9.5h6M9 16h6" stroke="#fff"/>',
    checkCircle: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="m8 12.3 2.8 2.8L16.3 9.5" stroke="#fff"/>',
    chevD: '<path d="m6.5 9.5 5.5 5.5 5.5-5.5"/>',
    chevU: '<path d="m6.5 14.5 5.5-5.5 5.5 5.5"/>',
    chevR: '<path d="m9.5 6 6 6-6 6"/>',
    toTop: '<path d="M5 4h14M12 20V8M7 13l5-5 5 5"/>',
    toBot: '<path d="M5 20h14M12 4v12M7 11l5 5 5-5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    people: '<circle cx="9" cy="8.5" r="3.3"/><path d="M3 19c.6-3.3 3-5 6-5s5.4 1.7 6 5"/><circle cx="16.5" cy="8.5" r="2.8"/><path d="M17 14c2.3.2 3.7 1.8 4 4.5"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.8v2.4M12 18.8v2.4M21.2 12h-2.4M5.2 12H2.8M18.5 5.5l-1.7 1.7M7.2 16.8l-1.7 1.7M18.5 18.5l-1.7-1.7M7.2 7.2 5.5 5.5"/><circle cx="12" cy="12" r="6.6"/>',
    compass: '<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5z"/>',
    more: '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="12" r=".6" fill="currentColor"/><circle cx="12" cy="12" r=".6" fill="currentColor"/><circle cx="16" cy="12" r=".6" fill="currentColor"/>',
    memory: '<rect x="5" y="7" width="14" height="10" rx="1.5"/><path d="M8 7V4.5M12 7V4.5M16 7V4.5M8 19.5V17M12 19.5V17M16 19.5V17"/>',
    hand: '<path d="M8 12V6.5a1.5 1.5 0 0 1 3 0V11m0-5.5V4.5a1.5 1.5 0 0 1 3 0V11m0-5a1.5 1.5 0 0 1 3 0v6m0-3a1.5 1.5 0 0 1 3 0v4.5A7.5 7.5 0 0 1 12.5 21h-.7a6.5 6.5 0 0 1-5.1-2.5L4 15a1.6 1.6 0 0 1 2.4-2.1L8 14.5"/>',
    cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx=".8"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>',
    gauge: '<path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="m12 13 3.5-4"/><circle cx="12" cy="13" r="1"/>',
    photo: '<rect x="3" y="5" width="15" height="13" rx="2"/><path d="m3 15 4-4 4 4 2-2 5 5M18.5 3v5M16 5.5h5"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    up: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    branch: '<circle cx="6.5" cy="5.5" r="2.2"/><circle cx="6.5" cy="18.5" r="2.2"/><circle cx="17.5" cy="7.5" r="2.2"/><path d="M6.5 7.7v8.6M17.5 9.7c0 4.3-5 4.3-9.5 7"/>',
    turn: '<path d="M6 4v7a3 3 0 0 0 3 3h10M15 10l4 4-4 4"/>',
    dotFill: '<circle cx="12" cy="12" r="5" fill="currentColor" stroke="none"/>',
    note: '<path d="M5 4h14v11l-5 5H5z"/><path d="M14 20v-5h5M8.5 9h7M8.5 12.5h4"/>',
    notePlus: '<path d="M5 4h10M5 4v16h9M5 20"/><path d="M8.5 9h6M8.5 12.5h4M18 13v7M14.5 16.5h7"/>',
    listIndent: '<path d="M4 6h16M8 12h12M8 18h12M4 11l2 1.5L4 14"/>',
    graph: '<circle cx="6" cy="6" r="2.3"/><circle cx="18" cy="6" r="2.3"/><circle cx="12" cy="18" r="2.3"/><path d="M7.4 7.8 10.8 16M16.6 7.8 13.2 16"/>',
    pencil: '<path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
    bolt: '<path d="M13 2.5 5 14h6l-1 7.5L18 10h-6z" fill="currentColor" stroke="none"/>',
    brain: '<path d="M9 4.5a3 3 0 0 0-3 3 3 3 0 0 0-1.5 5.6A3 3 0 0 0 7.5 18 2.5 2.5 0 0 0 12 19V6a2.5 2.5 0 0 0-3-1.5zM15 4.5a3 3 0 0 1 3 3 3 3 0 0 1 1.5 5.6 3 3 0 0 1-3 4.9A2.5 2.5 0 0 1 12 19"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.5 3.5 5.5 3.5 9s-1 6.5-3.5 9c-2.5-2.5-3.5-5.5-3.5-9s1-6.5 3.5-9z"/>',
    openOut: '<path d="M14 4h6v6M20 4l-8.5 8.5M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>',
    chatSeg: '<path d="M3 5.5A2.5 2.5 0 0 1 5.5 3h8A2.5 2.5 0 0 1 16 5.5v5a2.5 2.5 0 0 1-2.5 2.5H8L5 15.5V13a2.5 2.5 0 0 1-2-2.5z"/><path d="M16 8h2.5A2.5 2.5 0 0 1 21 10.5v5a2.5 2.5 0 0 1-2 2.5v2.5L16 18h-4"/>',
    lock: '<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
    folderFill: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h4l2 2h7A2.5 2.5 0 0 1 21 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16.5z" fill="currentColor" fill-opacity=".25"/>',
    tag: '<path d="M3 12V4.5A1.5 1.5 0 0 1 4.5 3H12l9 9-9 9z"/><circle cx="7.5" cy="7.5" r="1.3"/>'
  };
  function icon(name, cls) {
    return '<svg class="ic' + (cls ? " " + cls : "") + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || "") + "</svg>";
  }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

  var USERS = { arivera: "#3b4a63", mkato: "#2f8f74", sofia: "#7a62d4", jlee: "#c27b25", dvorak: "#b9503c", tnguyen: "#2d7fb0" };
  function av(login, size) {
    var st = 'background:' + (USERS[login] || "#556") + (size ? ";width:" + size + "px;height:" + size + "px;font-size:" + Math.round(size * 0.42) + "px" : "");
    return '<span class="y-av" style="' + st + '">' + login.charAt(0).toUpperCase() + "</span>";
  }

  var KW = ["const", "let", "var", "function", "return", "if", "else", "import", "from", "export", "await", "async", "new", "true", "false", "null", "it", "describe", "try", "catch", "finally", "type"];
  function hl(src) {
    var re = /(\/\/.*$)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)/g;
    var out = "", last = 0, m;
    while ((m = re.exec(src))) {
      out += esc(src.slice(last, m.index));
      var cls = m[1] ? "hc" : m[2] ? "hs" : m[3] ? "hn" : KW.indexOf(m[4]) >= 0 ? "hk" : "";
      out += cls ? '<span class="' + cls + '">' + esc(m[0]) + "</span>" : esc(m[0]);
      last = re.lastIndex;
    }
    return out + esc(src.slice(last));
  }

  var ST = {
    open: { icon: "pull", c: "var(--green)", fill: "var(--greenFill)", t: "Open" },
    draft: { icon: "draft", c: "var(--slate)", fill: "var(--slateFill)", t: "Draft" },
    merged: { icon: "merge", c: "var(--violet)", fill: "var(--violetFill)", t: "Merged" },
    closed: { icon: "closed", c: "var(--red)", fill: "var(--redFill)", t: "Closed" }
  };

  var USE_SEARCH_OLD = [
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
  ];
  var USE_SEARCH_NEW = [
    ["h", "", "", "@@ -18,9 +18,18 @@ export function useSearch(query) {"],
    ["", "18", "18", "  const [results, setResults] = useState([])"],
    ["", "19", "19", "  const [loading, setLoading] = useState(false)"],
    ["d", "20", "", "  useEffect(() => {"],
    ["d", "21", "", "    fetchResults(query).then(setResults)"],
    ["d", "22", "", "  }, [query])"],
    ["a", "", "20", "  const debounced = useDebounce(query, 250)"],
    ["a", "", "21", ""],
    ["a", "", "22", "  useEffect(() => {"],
    ["a", "", "23", "    if (!debounced) return setResults([])"],
    ["a", "", "24", "    const controller = new AbortController()", 1],
    ["a", "", "25", "    setLoading(true)"],
    ["a", "", "26", "    fetchResults(debounced, controller.signal)", 1],
    ["a", "", "27", "      .then(setResults)"],
    ["a", "", "28", "      .finally(() => setLoading(false))"],
    ["a", "", "29", "    return () => controller.abort()", 1],
    ["a", "", "30", "  }, [debounced])"],
    ["", "23", "31", ""],
    ["", "24", "32", "  return { results, loading }"]
  ];
  var AGENT_EDIT = [
    ["", "23", "23", "    if (!debounced) return setResults([])"],
    ["a", "", "24", "    const controller = new AbortController()"],
    ["", "24", "25", "    setLoading(true)"],
    ["d", "25", "", "    fetchResults(debounced)"],
    ["a", "", "26", "    fetchResults(debounced, controller.signal)"],
    ["", "26", "27", "      .then(setResults)"],
    ["", "27", "28", "      .finally(() => setLoading(false))"],
    ["a", "", "29", "    return () => controller.abort()"],
    ["", "28", "30", "  }, [debounced])"]
  ];

  var PRS = {
    482: {
      repo: "acme/web-app", title: "Speed up search with debounced queries", author: "arivera", state: "open", ago: "2h", created: "2h", add: 48, del: 12, base: "main", head: "feat/search-debounce",
      ci: "ok", review: "changes", comments: 3, stack: true,
      body: "Debounces the search box by 250 ms so we stop firing a request on every keystroke. Adds a small <code>useDebounce</code> hook with tests.",
      commits: [["Add useDebounce hook", "3h", "a3f9c21"], ["Debounce search queries", "3h", "7b1e044"], ["Show spinner while loading", "1h", "c09d5af"], ["Address lint", "1h", "e4a7713"]],
      checks: [["ok", "CI / build", "1m 12s"], ["ok", "CI / unit tests", "48s"], ["ok", "CI / lint", "21s"], ["ok", "e2e / chrome", "3m 40s"]],
      files: [
        { path: "src/search/useSearch.ts", st: "M", add: 18, del: 6 },
        { path: "src/hooks/useDebounce.ts", st: "A", add: 14, del: 0, lines: [
          ["h", "", "", "@@ -0,0 +1,10 @@"],
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
    485: { repo: "acme/web-app", title: "Saved searches", author: "arivera", state: "draft", ago: "1h", add: 76, del: 4, base: "feat/search-debounce", head: "feat/saved-searches", ci: "run", comments: 0, stack: true,
      body: "Lets people pin a query. Stacked on #482 so it reuses the debounced hook.", commits: [["Saved searches store", "1h", "5d2a8e1"]], checks: [["run", "CI / unit tests", "running"], ["ok", "CI / lint", "17s"]],
      files: [{ path: "src/search/saved.ts", st: "A", add: 18, del: 0, lines: [["h", "", "", "@@ -0,0 +1,4 @@"], ["a", "", "1", "export function useSavedSearches() {"], ["a", "", "2", "  const [saved, setSaved] = useStoredState(\"saved-searches\", [])"], ["a", "", "3", "  return { saved, save: (q: string) => setSaved([...saved, q]) }"], ["a", "", "4", "}"]] }] },
    480: { repo: "acme/web-app", title: "Search index endpoint", author: "arivera", state: "merged", ago: "3d", add: 131, del: 8, base: "main", head: "feat/search-index", ci: "ok", review: "ok", comments: 2, stack: true,
      body: "Adds <code>GET /search</code> backed by the new index. First PR in the search stack.", commits: [["Search index endpoint", "3d", "91be4c0"], ["Index tests", "3d", "0c47d1a"]], checks: [["ok", "CI / build", "1m 08s"], ["ok", "CI / unit tests", "51s"]],
      files: [{ path: "src/api/search.ts", st: "A", add: 24, del: 0, lines: [["h", "", "", "@@ -0,0 +1,4 @@"], ["a", "", "1", "export async function fetchResults(query: string) {"], ["a", "", "2", "  const res = await fetch(`/search?q=${encodeURIComponent(query)}`)"], ["a", "", "3", "  return res.json()"], ["a", "", "4", "}"]] }] },
    58: { repo: "acme/infra", title: "Bump dependencies for Q4", author: "arivera", state: "open", ago: "1d", add: 140, del: 131, base: "main", head: "chore/deps-q4", ci: "fail", review: "req", comments: 1,
      body: "Routine dependency bumps. Node 22, Terraform providers and the CI images.", commits: [["Bump node to 22", "1d", "f1a2b3c"], ["Bump terraform providers", "1d", "d4e5f6a"]], checks: [["fail", "plan / staging", "Failed · 2m 03s"], ["ok", "CI / lint", "12s"]],
      files: [{ path: ".github/workflows/ci.yml", st: "M", add: 2, del: 2, lines: [["h", "", "", "@@ -9,7 +9,7 @@ jobs:"], ["d", "9", "", "      node-version: 20"], ["a", "", "9", "      node-version: 22"]] }] },
    479: { repo: "acme/web-app", title: "Add dark mode to the settings screen", author: "jlee", state: "open", ago: "5h", add: 214, del: 37, base: "main", head: "feat/dark-settings", ci: "run", review: "req", comments: 0,
      body: "Moves settings colors to theme tokens and adds a light / dark / system picker.", commits: [["Theme tokens for settings", "6h", "aa12bc3"], ["Appearance picker", "5h", "bb34cd5"]], checks: [["ok", "CI / build", "1m 05s"], ["run", "CI / unit tests", "running"]],
      files: [{ path: "src/settings/Appearance.tsx", st: "A", add: 62, del: 0, lines: [["h", "", "", "@@ -0,0 +1,5 @@"], ["a", "", "1", "export function AppearancePicker() {"], ["a", "", "2", "  const [mode, setMode] = useAppearance()"], ["a", "", "3", "  return <Segmented value={mode} onChange={setMode}"], ["a", "", "4", "    options={[\"light\", \"dark\", \"system\"]} />"], ["a", "", "5", "}"]] }] },
    213: { repo: "acme/api", title: "Retry token refresh on 401", author: "sofia", state: "open", ago: "1d", add: 92, del: 18, base: "main", head: "fix/refresh-retry", ci: "fail", review: "req", comments: 2,
      body: "Retries the original request once after a successful token refresh.", commits: [["Retry once after refresh", "1d", "cc56de7"]], checks: [["fail", "CI / unit tests", "Failed · 58s"], ["ok", "CI / build", "58s"]],
      files: [{ path: "src/auth/client.ts", st: "M", add: 92, del: 18, lines: [["h", "", "", "@@ -40,6 +40,10 @@ async function request(req) {"], ["", "40", "40", "  const res = await fetch(req)"], ["a", "", "41", "  if (res.status === 401 && !req.retried) {"], ["a", "", "42", "    await refreshToken()"], ["a", "", "43", "    return request({ ...req, retried: true })"], ["a", "", "44", "  }"]] }] },
    470: { repo: "acme/ios", title: "Offline cache for the feed", author: "tnguyen", state: "open", ago: "2d", add: 305, del: 41, base: "main", head: "feat/offline-feed", ci: "ok", review: "req", comments: 4,
      body: "Caches the last 50 feed items on disk.", commits: [["Disk cache", "2d", "ee78f90"]], checks: [["ok", "CI / build", "4m 02s"]],
      files: [{ path: "App/Feed/FeedCache.swift", st: "A", add: 305, del: 0, lines: [["h", "", "", "@@ -0,0 +1,3 @@"], ["a", "", "1", "final class FeedCache {"], ["a", "", "2", "    private let url: URL"], ["a", "", "3", "}"]] }] },
    91: { repo: "acme/ios", title: "Haptics on pull to refresh", author: "dvorak", state: "open", ago: "just now", add: 22, del: 3, base: "main", head: "feat/pull-haptics", ci: "run", review: "req", comments: 0,
      body: "Plays a light haptic when the pull crosses the refresh threshold, once per gesture.", commits: [["Add haptic at refresh threshold", "just now", "9f0e1d2"]], checks: [["run", "CI / build", "running"], ["ok", "CI / lint", "18s"]],
      files: [{ path: "Sources/Shared/PullIndicator.swift", st: "M", add: 22, del: 3, lines: [["h", "", "", "@@ -12,6 +12,9 @@ struct PullIndicator: View {"], ["", "12", "12", "    .onChange(of: armed) { _, armed in"], ["a", "", "13", "        guard armed else { return }"], ["a", "", "14", "        haptics.perform(.alignment, performanceTime: .now)"], ["", "13", "15", "    }"]] }] }
  };
  PRS[482].files[0].lines = USE_SEARCH_OLD;
  var STACK = [480, 482, 485];

  var SECTIONS = [
    { h: "Inbox" },
    { id: "notifications", title: "Notifications", icon: "bell", c: "var(--amber)", count: 4 },
    { h: "Pull requests" },
    { id: "review", title: "Review requests", icon: "eye", c: "var(--sky)", list: [479, 470, 213] },
    { id: "mine", title: "Created by me", icon: "person", c: "var(--violet)", list: [482, 485, 58, 480] },
    { id: "assigned", title: "Assigned to me", icon: "personClock", c: "var(--teal)", list: [] },
    { id: "mentioned", title: "Mentioned", icon: "at", c: "var(--indigo)", list: [213] },
    { id: "reviewed", title: "Reviewed by me", icon: "checkBubble", c: "var(--green)", list: [470] },
    { id: "projects-mine", title: "My PRs by project", icon: "folder", c: "var(--coral)", list: [482, 485, 58] },
    { id: "stacks", title: "Stacks", icon: "stack", c: "var(--indigo)" },
    { h: "Issues" },
    { id: "i-assigned", title: "Assigned to me", icon: "personClock", c: "var(--teal)", issues: [[311, "Search results flicker on slow networks", "acme/web-app", "4h"]] },
    { id: "i-created", title: "Created by me", icon: "issue", c: "var(--green)", issues: [[305, "Debounce delay should be configurable", "acme/web-app", "1d"], [88, "Feed jumps after refresh", "acme/ios", "3d"]] },
    { id: "i-mentioned", title: "Mentioned", icon: "at", c: "var(--indigo)", issues: [] },
    { h: "Code" },
    { id: "repos", title: "Repositories", icon: "book", c: "var(--teal)" },
    { id: "projects", title: "Projects", icon: "board", c: "var(--indigo)" },
    { h: "AI" },
    { id: "agents", title: "Agents", icon: "terminal", c: "var(--coral)" }
  ];
  function sec(id) { for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === id) return SECTIONS[i]; }

  var NOTIFS = [
    { pr: 482, kind: "pull", c: "var(--violet)", title: "Speed up search with debounced queries", reason: "comment", rc: "", ago: "2h", unread: true },
    { pr: 479, kind: "pull", c: "var(--violet)", title: "Add dark mode to the settings screen", reason: "review requested", rc: "var(--sky)", ago: "5h", unread: true },
    { pr: 58, kind: "octagon", c: "var(--red)", title: "plan / staging failed on chore/deps-q4", reason: "CI", rc: "", ago: "1d", unread: true },
    { pr: 213, kind: "pull", c: "var(--violet)", title: "Retry token refresh on 401", reason: "mention", rc: "var(--amber)", ago: "1d", unread: true },
    { pr: 480, kind: "pull", c: "var(--violet)", title: "Search index endpoint", reason: "author", rc: "", ago: "3d", unread: false }
  ];
  var REPOS = [["acme/web-app", "Customer web app", "TypeScript", "#3178c6"], ["acme/api", "Public REST API", "Go", "#00add8"], ["acme/ios", "iOS client", "Swift", "#f05138"], ["acme/infra", "Terraform and CI", "HCL", "#844fba"]];

  var FIX_TITLE = "Fix PR #482: Speed up search with debounced queries";
  var PROMPT = "Address the code review feedback on pull request #482 \"Speed up search with debounced queries\" in acme/web-app.\n\n1. src/search/useSearch.ts:26 (@sofia)\n   Cancel the in-flight request when the query changes, otherwise stale results can win the race.\n\nWhen done: commit, then push to feat/search-debounce.";

  var SCRIPT = [
    { k: "user", d: 300 },
    { k: "text", d: 900, text: "I'll look at how <code>useSearch</code> fetches results first." },
    { k: "group", id: "g1", d: 700, steps: [["read", "Read src/search/useSearch.ts"], ["search", "Searched for \"fetchResults\""], ["read", "Read src/api/search.ts"]] },
    { k: "text", d: 900, text: "Each query should get its own <code>AbortController</code>, and the effect should abort it when the query changes." },
    { k: "edit", id: "e1", d: 900 },
    { k: "text", d: 700, text: "Now I'll run the search tests." },
    { k: "perm", d: 600 },
    { k: "bash", id: "b1", d: 300, run: 1800 },
    { k: "group", id: "g2", d: 900, steps: [["cmd", "Commit the fix", "git commit -am \"Abort stale search requests\""], ["cmd", "Push to the PR branch", "git push origin HEAD:feat/search-debounce"]], push: true },
    { k: "tool", id: "n1", d: 700 },
    { k: "text", d: 900, final: true, text: "Done. Each query now aborts the previous request, so a slow response can't overwrite newer results. All 12 search tests pass. I pushed <code>b81c0de</code> to <code>feat/search-debounce</code> and left a stack note for #485." }
  ];

  var state;
  function initState() {
    state = {
      section: "mine", pr: 482, tab: "conversation", file: 0, filter: "open", diffMode: "unified", detail: "pr",
      reviewCount: 3, newPR: false, rerq: "show", fixed: false, pushed: false, requestedAt: 0,
      agent: null, sheet: false, toast: null, palette: null, notes: false, showDetail: true, inspector: false, itab: "changes", stackView: "list", convScroll: 0
    };
  }
  initState();

  function sectionCount(s) {
    if (s.id === "review") return state.reviewCount;
    if (s.id === "mine") return s.list.filter(function (id) { return PRS[id].state !== "merged"; }).length;
    if (s.id === "notifications") return s.count;
    if (s.id === "agents") return agentBadge();
    return 0;
  }

  function agentStatus() {
    var a = state.agent;
    if (!a) return null;
    if (a.waiting) return "wait";
    if (a.busy) return "work";
    if (a.done && !a.seen) return "done";
    return "idle";
  }
  function agentBadge() {
    var s = agentStatus();
    return s === "wait" || s === "done" || s === "work" ? 1 : 0;
  }

  root.innerHTML = '<div class="y-tb"></div><nav class="y-side" aria-label="Sidebar"></nav><div class="y-list"></div><div class="y-det"></div><div class="y-cur" aria-hidden="true"><i></i><svg viewBox="0 0 24 24"><path d="M5 2.5v16.8l4.3-4.1 2.8 6.3 2.6-1.1-2.7-6.2h6z" fill="#fff" stroke="#111" stroke-width="1.2" stroke-linejoin="round"/></svg></div>';
  var elTb = root.querySelector(".y-tb"), elSide = root.querySelector(".y-side"), elList = root.querySelector(".y-list"), elDet = root.querySelector(".y-det"), elCur = root.querySelector(".y-cur");

  function platform() { return document.documentElement.getAttribute("data-platform") || "mac"; }
  function mod() { return platform() === "mac" ? "⌘" : "Ctrl+"; }

  var lastPos = {};
  function slideTo(el, key, x, w) {
    if (!el) return;
    var t = "translateX(" + x + "px) scaleX(" + w / 100 + ")";
    el.style.width = "100px";
    el.style.transformOrigin = "0 0";
    el.style.transition = "none";
    el.style.transform = lastPos[key] || t;
    void el.offsetWidth;
    el.style.transition = "";
    el.style.transform = t;
    lastPos[key] = t;
  }

  function title() {
    if (state.section === "agents") return ["Agents", ""];
    var s = sec(state.section);
    if (s.list) {
      var n = visibleList().length;
      return [s.title, n + (n === 1 ? " result" : " results")];
    }
    if (s.issues) return ["Issues: " + s.title, s.issues.length + (s.issues.length === 1 ? " result" : " results")];
    if (state.section === "stacks") return ["Stacks", "1"];
    if (state.section === "repos") return ["Repositories", REPOS.length + " repositories"];
    return [s.title, ""];
  }

  function renderToolbar() {
    var t = title();
    var h = '<div class="y-lights"><i></i><i></i><i></i></div><div class="y-gl c hide-m"><button aria-label="Hide sidebar">' + icon("sidebar") + "</button></div>";
    h += '<div class="y-tt"><b>' + esc(t[0]) + "</b>" + (t[1] ? "<small>" + t[1] + "</small>" : "") + '</div><span class="y-tbsp"></span>';
    var prOpen = state.section !== "agents" && state.detail === "pr" && state.pr;
    if (state.section === "agents") {
      h += '<div class="y-gl hide-s"><button aria-label="Open folder">' + icon("folderPlus") + '</button><button aria-label="Refresh">' + icon("refresh") + "</button></div>";
      if (state.agent) h += '<div class="y-gl c hide-s"><button data-insp aria-label="Inspector">' + icon("sidebarR") + "</button></div>";
      h += '<div class="y-search">' + icon("search") + "<span>Search sessions</span></div>";
    } else if (prOpen) {
      var p = PRS[state.pr];
      h += '<div class="y-gl hide-s"><button data-refresh aria-label="Refresh">' + icon("refresh") + '</button><span class="y-status">' + icon("refresh") + '<span data-ago>' + agoShort() + "</span></span></div>";
      h += '<div class="y-gl"><button>' + icon("checkBubble") + '<span class="lbl">Review</span></button><span class="sep"></span><button aria-label="Review options" style="padding:0 10px">' + icon("chevD") + "</button></div>";
      if (p.state === "open" || p.state === "draft") h += '<div class="y-gl"><button data-fix>' + icon("wrench") + "<span>Fix with agent</span></button>" + (p.state === "open" ? "<button>" + icon("merge") + '<span class="lbl">Merge</span></button>' : "") + "</div>";
      h += '<div class="y-gl c hide-s"><button aria-label="Open in browser">' + icon("compass") + '</button></div><div class="y-gl hide-s"><button aria-label="More" style="padding:0 10px">' + icon("more") + icon("chevD") + "</button></div>";
      h += '<div class="y-search" style="width:34px;flex:none;padding:0;justify-content:center">' + icon("search") + "</div>";
    } else {
      h += '<div class="y-gl c"><button data-refresh aria-label="Refresh">' + icon("refresh") + "</button></div>";
      var ph = state.section === "repos" ? "Filter repositories" : "Filter: text, repo:org/name, label:bug";
      h += '<div class="y-search" data-palette>' + icon("search") + "<span>" + ph + "</span></div>";
    }
    h += '<div class="y-wc" aria-hidden="true"><i><svg viewBox="0 0 10 10"><path d="M1 5h8"/></svg></i><i><svg viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8"/></svg></i><i><svg viewBox="0 0 10 10"><path d="m1 1 8 8M9 1 1 9"/></svg></i></div>';
    elTb.innerHTML = h;
  }

  function renderSidebar() {
    var h = '<div class="y-snav">';
    SECTIONS.forEach(function (s) {
      if (s.h) { h += '<div class="y-sh">' + s.h + "</div>"; return; }
      var n = sectionCount(s);
      h += '<button class="y-it' + (state.section === s.id ? " on" : "") + '" data-sec="' + s.id + '" style="--c:' + s.c + '" title="' + s.title + '"><span class="y-tile">' + icon(s.icon) + "</span><span>" + s.title + '</span><span class="y-cnt" data-cnt="' + s.id + '">' + (n || "") + "</span></button>";
    });
    h += '</div><div class="y-foot">' + av("arivera", 24) + '<div><b>Alex Rivera</b><small>@arivera</small></div><button aria-label="Switch account">' + icon("people") + '</button><button aria-label="Settings">' + icon("gear") + "</button></div>";
    elSide.innerHTML = h;
  }
  function updateSidebar() {
    Array.prototype.forEach.call(elSide.querySelectorAll(".y-it"), function (b) {
      b.classList.toggle("on", b.getAttribute("data-sec") === state.section);
      var s = sec(b.getAttribute("data-sec")), n = sectionCount(s);
      var c = b.querySelector(".y-cnt");
      if (c.textContent !== String(n || "")) c.textContent = n || "";
    });
  }

  function visibleList() {
    var s = sec(state.section);
    if (!s || !s.list) return [];
    return s.list.filter(function (id) {
      var st = PRS[id].state;
      return state.filter === "all" || (state.filter === "open" ? st === "open" || st === "draft" : st === "merged" || st === "closed");
    });
  }

  function ciIcon(ci) {
    if (ci === "ok") return '<span class="g">' + icon("check") + "</span>";
    if (ci === "fail") return '<span class="r">' + icon("x") + "</span>";
    if (ci === "run") return '<span class="a">' + icon("dotted") + "</span>";
    return "";
  }
  function reviewIcon(r) {
    if (r === "ok") return '<span class="g">' + icon("seal") + "</span>";
    if (r === "changes") return '<span class="r">' + icon("exBubble") + "</span>";
    if (r === "req") return '<span class="m">' + icon("eye") + "</span>";
    return "";
  }
  function diffStat(a, d) { return '<span class="y-ds"><i class="g">+' + a.toLocaleString("en-US") + '</i><i class="r">−' + d.toLocaleString("en-US") + "</i></span>"; }
  function badge(stName) { var s = ST[stName]; return '<span class="y-badge" style="--c:' + s.c + '">' + icon(s.icon) + "</span>"; }

  function prRow(id, cls) {
    var p = PRS[id];
    return '<button class="y-row' + (state.detail === "pr" && state.pr === id ? " on" : "") + (cls ? " " + cls : "") + '" data-pr="' + id + '">' + badge(p.state) + '<span class="y-rt"><b>' + esc(p.title) + '</b><span class="y-rl"><span>' + p.repo + "#" + id + '</span><span class="y-sep">·</span><span>' + (p.ago === "just now" ? "just now" : p.ago + " ago") + '</span><span class="sp"></span>' + diffStat(p.add, p.del) + '</span><span class="y-rl">' + av(p.author) + "<span>" + p.author + '</span><span class="sp"></span><span class="y-ricons">' + ciIcon(p.ci) + reviewIcon(p.review) + (p.comments ? "<span>" + icon("bubble") + p.comments + "</span>" : "") + "</span></span></span></button>";
  }

  function segHTML(name, opts, cur, cls) {
    return '<div class="y-seg' + (cls ? " " + cls : "") + '" data-segname="' + name + '"><span class="y-thumb"></span>' + opts.map(function (o) { return '<button data-' + name + '="' + o[0] + '" class="' + (o[0] === cur ? "on" : "") + '">' + o[1] + "</button>"; }).join("") + "</div>";
  }
  function placeSegs(scope) {
    Array.prototype.forEach.call(scope.querySelectorAll(".y-seg"), function (s) {
      var on = s.querySelector("button.on"), th = s.querySelector(".y-thumb");
      if (on && th) slideTo(th, "seg:" + s.getAttribute("data-segname"), on.offsetLeft, on.offsetWidth);
    });
  }

  function renderList(anim) {
    var s = sec(state.section), h = "";
    if (state.section === "agents") { elList.innerHTML = agentList(anim); return; }
    if (s.list) {
      h += '<div class="y-lhead">' + segHTML("filter", [["open", "Open"], ["closed", "Closed"], ["all", "All"]], state.filter) + '</div><div class="y-rows">';
      var ids = visibleList();
      if (!ids.length) h += '<div class="y-empty">No pull requests</div>';
      ids.forEach(function (id, i) { h += prRow(id, anim ? "y-cascade" : ""); });
      h += "</div>" + listFooter();
    } else if (s.issues) {
      h += '<div class="y-lhead">' + segHTML("filter", [["open", "Open"], ["closed", "Closed"], ["all", "All"]], "open") + '</div><div class="y-rows">';
      if (!s.issues.length) h += '<div class="y-empty">No issues</div>';
      s.issues.forEach(function (it) {
        h += '<button class="y-row' + (anim ? " y-cascade" : "") + '"><span class="y-badge" style="--c:var(--green)">' + icon("issue") + '</span><span class="y-rt"><b>' + esc(it[1]) + '</b><span class="y-rl"><span>' + it[2] + "#" + it[0] + '</span><span class="y-sep">·</span><span>' + it[3] + " ago</span></span></span></button>";
      });
      h += "</div>" + listFooter();
    } else if (state.section === "notifications") {
      h += '<div class="y-lhead" style="padding:8px 10px">' + segHTML("nfilter", [["unread", "Unread"], ["all", "All"]], "unread") + '</div><div class="y-rows y-notif">';
      NOTIFS.forEach(function (n) {
        var p = PRS[n.pr];
        h += '<button class="y-row' + (anim ? " y-cascade" : "") + (state.detail === "pr" && state.pr === n.pr ? " on" : "") + '" data-pr="' + n.pr + '"><span class="y-ud' + (n.unread ? "" : " read") + '"></span><span class="y-sq" style="--c:' + n.c + '">' + icon(n.kind) + '</span><span class="y-rt"><b style="font-weight:' + (n.unread ? 600 : 400) + ";color:" + (n.unread ? "var(--text)" : "var(--muted)") + '">' + esc(n.title) + '</b><span class="y-rl">' + av(p.repo.split("/")[0], 13) + "<span>" + p.repo + '</span><span class="y-sep">·</span><span' + (n.rc ? ' style="color:' + n.rc + '"' : "") + ">" + n.reason + '</span><span class="y-sep">·</span><span class="dm">' + n.ago + "</span></span></span></button>";
      });
      h += "</div>" + listFooter();
    } else if (state.section === "stacks") {
      h += '<div class="y-rows">';
      h += '<button class="y-row y-stk-r' + (anim ? " y-cascade" : "") + '" data-pr="482" data-tabgo="stack" style="flex-direction:column;gap:4px"><span class="y-rl" style="font-size:13px;color:var(--text);gap:6px"><span style="color:var(--indigo);display:flex">' + icon("stack") + '</span><b style="font-weight:500">#480 Search index endpoint</b></span><span class="y-rl"><span>acme/web-app</span><span class="y-sep">·</span><span>on main</span><span class="y-sep">·</span><span>3 days ago</span></span><span class="y-rl"><span class="caps">' + STACK.map(function (id) { return '<i style="--c:' + ST[PRS[id].state].c + '"></i>'; }).join("") + "</span><span>3 PRs</span></span></button>";
      h += "</div>" + listFooter();
    } else if (state.section === "repos") {
      h += '<div class="y-rows">';
      REPOS.forEach(function (r) {
        h += '<button class="y-row' + (anim ? " y-cascade" : "") + '"><span class="y-sq" style="--c:var(--teal)">' + icon("book") + '</span><span class="y-rt"><b>' + r[0] + '</b><span class="y-rl"><span>' + r[1] + '</span></span><span class="y-rl"><i style="width:8px;height:8px;border-radius:50%;background:' + r[3] + '"></i><span>' + r[2] + "</span></span></span></button>";
      });
      h += "</div>";
    } else {
      h += '<div class="y-rows"><button class="y-row' + (anim ? " y-cascade" : "") + '"><span class="y-sq" style="--c:var(--indigo)">' + icon("board") + '</span><span class="y-rt"><b>Q4 roadmap</b><span class="y-rl"><span>acme · 12 items</span></span></span></button></div>';
    }
    elList.innerHTML = h;
    if (anim) stagger(elList.querySelectorAll(".y-cascade"));
    placeSegs(elList);
  }
  function stagger(nodes) {
    Array.prototype.forEach.call(nodes, function (n, i) { n.style.animationDelay = (reduced() ? 0 : Math.min(i, 11) * 35) + "ms"; });
  }
  function listFooter() { return '<div class="y-lfoot">' + icon("refresh") + "<span>Updated <span data-ago>" + agoShort() + "</span></span></div>"; }

  var updatedAt = Date.now();
  function agoShort() {
    var s = Math.max(0, Math.round((Date.now() - updatedAt) / 1000));
    return s < 10 ? "just now" : s < 60 ? Math.floor(s / 5) * 5 + "s ago" : Math.floor(s / 60) + "m ago";
  }

  function updateListSelection() {
    Array.prototype.forEach.call(elList.querySelectorAll(".y-row[data-pr]"), function (r) {
      r.classList.toggle("on", state.detail === "pr" && +r.getAttribute("data-pr") === state.pr && state.section !== "stacks");
    });
  }

  function checksBadge(p) {
    var f = p.checks.filter(function (c) { return c[0] === "fail"; }).length;
    var r = p.checks.filter(function (c) { return c[0] === "run"; }).length;
    if (f) return '<em class="r">✕' + f + "</em>";
    if (r) return '<em class="a">…' + r + "</em>";
    return '<em class="g">✓' + p.checks.length + "</em>";
  }

  function unresolved(p) { return state.pr === 482 && !state.pushed ? 1 : 0; }

  function mergeBar(p) {
    if (p.state === "merged") return "";
    var txt, ic, c;
    if (state.pr === 482 && !state.pushed) { txt = "Changes requested"; ic = "plusminus"; c = "var(--red)"; }
    else if (state.pr === 482) { txt = "Review required"; ic = "eye"; c = "var(--amber)"; }
    else if (p.state === "draft") { txt = "Draft — mark it ready for review to merge"; ic = "draft"; c = "var(--slate)"; }
    else if (p.ci === "fail") { txt = "1 required check failed"; ic = "octagon"; c = "var(--red)"; }
    else if (p.review === "req") { txt = "Review required"; ic = "eye"; c = "var(--amber)"; }
    else { txt = "Ready to merge"; ic = "checkCircle"; c = "var(--green)"; }
    var f = p.checks.filter(function (x) { return x[0] === "fail"; }).length, r = p.checks.filter(function (x) { return x[0] === "run"; }).length, ok = p.checks.length - f - r;
    var mini = f ? '<span class="mini r">' + icon("octagon") + f + "</span>" : "";
    mini += r ? '<span class="mini a">' + icon("dotted") + r + "</span>" : "";
    mini += ok ? '<span class="mini g">' + icon("checkCircle") + ok + "</span>" : "";
    return '<div class="y-bnr" style="--c:' + c + '"><span style="color:' + c + ';display:flex">' + icon(ic) + '</span><span class="tx">' + txt + "</span>" + mini + '<span class="sp"></span><span class="y-btn">Merge…</span><span class="m" style="display:flex">' + icon("chevD") + "</span></div>";
  }

  function bannersHTML(p) {
    var h = "";
    if (state.pr === 482) {
      if (state.rerq === "show") h += '<div class="y-bnr' + (state.rerqAnim ? " y-reveal" : "") + '" data-bnr="rerq" style="--c:var(--sky)"><span class="y-sq" style="--c:var(--sky)">' + icon("cycle") + '</span><span class="tx">You pushed ' + (state.pushed ? "1 commit" : "2 commits") + ' after @sofia reviewed</span><span class="m">· ' + (state.pushed ? "now" : "1h ago") + '</span><span class="sp"></span><button class="y-btn">Other…</button><button class="y-btn p" data-rerq style="--c:var(--accentFill)">' + icon("cycle") + "Re-request review</button></div>";
      else if (state.rerq === "sending") h += '<div class="y-bnr" data-bnr="rerq" style="--c:var(--sky)"><span class="y-sq" style="--c:var(--sky)">' + icon("cycle") + '</span><span class="tx">You pushed 2 commits after @sofia reviewed</span><span class="m">· 1h ago</span><span class="sp"></span><button class="y-btn">Other…</button><button class="y-btn p" style="--c:var(--accentFill)"><span class="y-spin"></span>Re-request review</button></div>';
      else if (state.rerq === "done") h += '<div class="y-bnr y-reveal" data-bnr="rerq" style="--c:var(--sky)"><span class="g" style="display:flex">' + icon("checkCircle") + '</span><b style="font-weight:600">Requested</b><span class="m tx">· Review re-requested from @sofia</span></div>';
      if (unresolved(p)) h += '<div class="y-bnr" data-bnr="fix" style="--c:var(--coral)"><span class="y-sq" style="--c:var(--coral)">' + icon("wrench") + '</span><span class="tx">1 unresolved comment</span><span class="sp"></span><button class="y-btn p" data-fix style="--c:var(--coral)">Fix with agent</button></div>';
    }
    if (p.ci === "fail") h += '<div class="y-bnr" style="--c:var(--red);--t:7%"><span class="y-sq" style="--c:var(--red)">' + icon("octagon") + '</span><span class="tx">1 check failing</span><span class="m tx">· ' + p.checks[0][1] + '</span><span class="sp"></span><button class="y-btn">Re-run failed…</button><button class="y-btn p" style="--c:var(--coral)">Fix with agent</button></div>';
    return h;
  }

  function renderBanners() {
    var b = elDet.querySelector(".y-banners");
    if (!b) return;
    var p = PRS[state.pr];
    var old = b.querySelector('[data-bnr="rerq"]');
    b.innerHTML = mergeBar(p) + bannersHTML(p);
    state.rerqAnim = false;
  }

  function prDetail() {
    var p = PRS[state.pr], s = ST[p.state];
    var h = '<div class="y-route"><button class="y-back" data-back>' + icon("arrowL") + 'Back</button><div class="y-head"><div class="y-h1"><h3>' + esc(p.title) + "</h3><span>#" + state.pr + "</span>" + icon("link") + "</div>";
    h += '<div class="y-meta"><span class="y-pill" style="background:' + s.fill + '">' + icon(s.icon) + s.t + "</span>" + av(p.author) + "<b>" + p.author + '</b><span class="y-chip" style="--c:var(--sky)">' + p.base + '</span><span class="dm" style="display:flex">' + icon("arrowL") + '</span><span class="y-chip" style="--c:var(--violet)">' + p.head + "</span>" + diffStat(p.add + (state.pushed && state.pr === 482 ? 3 : 0), p.del + (state.pushed && state.pr === 482 ? 1 : 0)) + '<span class="sp"></span><span class="ag">' + (p.created || p.ago) + (p.ago === "just now" && !p.created ? "" : " ago") + "</span></div>";
    if (p.stack) {
      var idx = STACK.indexOf(state.pr);
      h += '<div class="y-strip">' + icon("stack") + '<b style="font-weight:600">Stack</b><span class="m">' + (idx + 1) + " of " + STACK.length + '</span><span class="caps">' + STACK.map(function (id) { return '<i class="' + (id === state.pr ? "cur" : "") + '" style="--c:' + ST[PRS[id].state].c + '"></i>'; }).join("") + '</span><span class="nav">' + (idx > 0 ? "<span>" + icon("chevD") + "#" + STACK[idx - 1] + "</span>" : "") + (idx < STACK.length - 1 ? "<span>" + icon("chevU") + "#" + STACK[idx + 1] + "</span>" : "") + icon("chevR") + "</span></div>";
    }
    h += "</div>";
    h += '<div class="y-banners">' + mergeBar(p) + bannersHTML(p) + "</div>";
    h += '<div class="y-tabs">' + tabsHTML(p) + '<span class="y-ul"></span></div><div class="y-body"></div></div>';
    return h;
  }

  function tabsHTML(p) {
    var u = unresolved(p);
    var tabs = [["conversation", "Conversation", "bubbles", u ? "<em>" + u + "</em>" : ""], ["commits", "Commits", "commits", "<em>" + (p.commits.length + (state.pushed && state.pr === 482 ? 1 : 0)) + "</em>"], ["checks", "Checks", "checklist", checksBadge(p)], ["files", "Files changed", "doc", "<em>" + p.files.length + "</em>"]];
    if (p.stack) tabs.push(["stack", "Stack", "stack", "<em>3</em>"]);
    if (!tabs.some(function (t) { return t[0] === state.tab; })) state.tab = "conversation";
    return tabs.map(function (t) { return '<button data-tab="' + t[0] + '" class="' + (state.tab === t[0] ? "on" : "") + '" aria-label="' + t[1] + '">' + icon(t[2]) + '<span class="tl">' + t[1] + "</span>" + t[3] + "</button>"; }).join("");
  }
  function placeTabUL() {
    var tabs = elDet.querySelector(".y-tabs");
    if (tabs) { tabs.classList.remove("icons"); if (tabs.scrollWidth > tabs.clientWidth + 1) tabs.classList.add("icons"); }
    var ul = elDet.querySelector(".y-ul"), on = elDet.querySelector(".y-tabs .on");
    if (ul && on) slideTo(ul, "tab", on.offsetLeft + 4, on.offsetWidth - 8);
  }
  function refreshTabs() {
    var t = elDet.querySelector(".y-tabs");
    if (!t) return;
    t.innerHTML = tabsHTML(PRS[state.pr]) + '<span class="y-ul"></span>';
    placeTabUL();
  }

  function renderBody() {
    var b = elDet.querySelector(".y-body");
    if (!b) return;
    var p = PRS[state.pr], h = '<div class="y-pane">';
    if (state.tab === "conversation") h += convView(p);
    else if (state.tab === "commits") h += commitsView(p);
    else if (state.tab === "checks") h += checksView(p);
    else if (state.tab === "files") h += filesView(p);
    else if (state.tab === "stack") h += stackView(p);
    b.innerHTML = h + "</div>";
    placeSegs(b);
  }

  function convView(p) {
    var h = '<div class="y-scroll"><div class="y-inner" style="transform:translateY(' + -state.convScroll + 'px)"><div class="y-conv">';
    h += '<div class="y-item">' + av(p.author, 32) + '<div class="y-box"><div class="y-bh' + (p.author === "arivera" ? " mine" : "") + '"><b>' + p.author + "</b><span>description</span><span>·</span><span>" + (p.created || p.ago) + ' ago</span></div><div class="y-bb">' + p.body + "</div></div></div>";
    if (state.pr === 482) {
      h += '<div class="y-ev"><span class="ei">' + icon("commits") + "</span>" + av("arivera") + '<b>arivera</b><span>pushed 2 commits</span><span class="dm">1h ago</span></div>';
      var res = state.pushed;
      h += '<div class="y-item">' + av("sofia", 32) + '<div class="y-box"><div class="y-bh"><b>sofia</b><span class="r" style="font-weight:600">± requested changes</span><span>·</span><span>1h ago</span></div><div class="y-bb"><div class="y-thr"><div class="y-ths">' + icon(res ? "chevR" : "chevD") + "<span>src/search/useSearch.ts</span><span class=\"m\">:26</span>" + (res ? '<span class="pl" style="color:var(--muted);background:var(--line)">outdated</span>' : "") + "</div>";
      if (!res) {
        h += '<div class="y-hk">' + [["", "    setLoading(true)"], ["a", "+    fetchResults(debounced)"], ["a", "+      .then(setResults)"]].map(function (l) { return '<div class="' + l[0] + '">' + esc(l[1]) + "</div>"; }).join("") + "</div>";
        h += '<div class="y-tc">' + av("sofia", 20) + "<div><small><b>sofia</b> · 1h</small>Cancel the in-flight request when the query changes, otherwise stale results can win the race.</div></div>";
        h += '<div class="y-tacts"><span>Reply</span><span>Resolve</span><span>View in files</span></div>';
      }
      h += "</div></div></div></div>";
      if (state.pushed) h += '<div class="y-ev y-rise"><span class="ei">' + icon("commits") + "</span>" + av("arivera") + '<b>arivera</b><span>commit <code>b81c0de</code> Abort stale search requests</span><span class="dm">now</span></div>';
      if (state.rerq === "done" || state.rerq === "gone") h += '<div class="y-ev y-rise"><span class="ei">' + icon("eye") + "</span>" + av("arivera") + '<b>arivera</b><span>requested review from → <b>sofia</b></span><span class="dm">now</span></div>';
    }
    h += "</div></div></div>";
    return h + '<div class="y-comp"><div>Comment (Markdown) — ' + mod() + '↩ to send</div><span class="y-btn lg" style="background:var(--slateFill);color:#fff;opacity:.6">Comment</span></div>';
  }

  function commitsView(p) {
    var list = p.commits.slice();
    if (state.pr === 482 && state.pushed) list.push(["Abort stale search requests", "now", "b81c0de", true]);
    return '<div class="y-list2">' + list.slice().reverse().map(function (c) {
      var ci = c[3] ? '<span class="a">' + icon("dotted") + "</span>" : '<span class="g">' + icon("check") + "</span>";
      return '<div class="y-cr' + (c[3] ? " new" : "") + '">' + av(p.author, 22) + "<div><b>" + esc(c[0]) + "</b><small>" + p.author + " · " + (c[1] === "now" ? "now" : c[1] + " ago") + "</small></div>" + ci + "<code>" + c[2] + "</code></div>";
    }).join("") + "</div>";
  }

  function checksView(p) {
    var order = { fail: 0, run: 1, ok: 2 };
    return '<div class="y-list2">' + p.checks.slice().sort(function (a, b) { return order[a[0]] - order[b[0]]; }).map(function (c) {
      var ic = c[0] === "ok" ? '<span class="g">' + icon("checkCircle") + "</span>" : c[0] === "fail" ? '<span class="r">' + icon("octagon") + "</span>" : '<span class="a"><span class="y-spin"></span></span>';
      var sub = c[0] === "ok" ? "Successful · " + c[2] : c[0] === "fail" ? c[2] : "In progress";
      return '<div class="y-cr">' + ic + "<div><b>" + c[1] + "</b><small>" + sub + "</small></div>" + (c[0] === "fail" ? '<span class="y-btn p" style="--c:var(--coral)">Fix with agent</span><span class="y-btn">Log</span>' : '<span class="y-btn">Log</span>') + "</div>";
    }).join("") + "</div>";
  }

  function filesView(p) {
    var idx = Math.min(state.file, p.files.length - 1), f = p.files[idx];
    var lines = state.pr === 482 && idx === 0 ? (state.pushed ? USE_SEARCH_NEW : USE_SEARCH_OLD) : f.lines;
    var h = '<div class="y-files"><div class="y-fl"><div class="y-ff"><span>Filter files</span><span>0/' + p.files.length + "</span></div>";
    p.files.forEach(function (file, i) {
      var parts = file.path.split("/"), name = parts.pop();
      h += '<button class="y-file' + (i === idx ? " on" : "") + '" data-file="' + i + '"><i style="color:' + (file.st === "A" ? "var(--green)" : "var(--amber)") + '">' + file.st + "</i><span><b>" + name + "</b><small>" + parts.join("/") + "</small></span></button>";
    });
    h += '</div><div class="y-dv"><div class="y-rb"><span class="nb"><span>' + icon("chevU") + "</span><span>" + icon("chevD") + '</span></span><span class="nb"><span>' + icon("toTop") + "</span><span>" + icon("toBot") + '</span></span><span class="sp"></span><span class="y-cb"><i>' + icon("check") + "</i>Wrap lines</span>" + segHTML("mode", [["unified", "Unified"], ["split", "Split"]], state.diffMode, "sm mute") + "</div>";
    h += '<div class="y-fh">' + icon("chevD") + '<span class="p">' + f.path + "</span>" + diffStat(f.add + (state.pushed && state.pr === 482 && idx === 0 ? 3 : 0), f.del + (state.pushed && state.pr === 482 && idx === 0 ? 1 : 0)) + '<span class="sp"></span><span class="y-cb"><i class="off"></i>Viewed</span>' + icon("more") + "</div>";
    h += '<div class="y-diff">' + (state.diffMode === "split" ? splitDiff(lines) : lines.map(function (l) { return lineHTML(l, state.flashNew); }).join("")) + "</div></div></div>";
    return h;
  }
  function pad5(n) { n = String(n); return "     ".slice(n.length) + n; }
  function lineHTML(l, flash) {
    if (l[0] === "h") return '<div class="y-ln h"><span></span><span>' + esc(l[3]) + "</span></div>";
    var sign = l[0] === "a" ? "+" : l[0] === "d" ? "-" : " ";
    return '<div class="y-ln ' + l[0] + (flash && l[4] ? " new" : "") + '"><span>' + pad5(l[1]) + " " + pad5(l[2]) + "</span><span>" + sign + " " + hl(l[3]) + "</span></div>";
  }
  function splitDiff(lines) {
    var rows = [], dels = [], adds = [];
    function flush() { for (var i = 0; i < Math.max(dels.length, adds.length); i++) rows.push([dels[i] || null, adds[i] || null]); dels = []; adds = []; }
    lines.forEach(function (l) { if (l[0] === "d") dels.push(l); else if (l[0] === "a") adds.push(l); else { flush(); rows.push(l[0] === "h" ? l : [l, l]); } });
    flush();
    function cell(l, side) {
      if (!l) return '<span class="n e"></span><span class="c e"></span>';
      var c = l[0] ? " " + l[0] : "";
      return '<span class="n' + c + '">' + (side ? l[2] : l[1]) + '</span><span class="c' + c + '">' + hl(l[3]) + "</span>";
    }
    return rows.map(function (r) {
      if (r[0] === "h") return '<div class="y-ln h"><span></span><span>' + esc(r[3]) + "</span></div>";
      return '<div class="y-sp">' + cell(r[0], 0) + cell(r[1], 1) + "</div>";
    }).join("");
  }

  function stackView(p) {
    var h = '<div class="y-stk"><div class="y-stkb">' + segHTML("sview", [["list", icon("listIndent") + "List"], ["graph", icon("graph") + "Graph"]], "list", "sm mute") + '<span>3 pull requests on main</span><span class="sp" style="flex:1"></span>' + icon("refresh") + '</div><div class="y-stkl"><div class="y-sbase">' + icon("branch") + "main</div>";
    var notes = { 480: 0, 482: state.noteAdded ? 2 : 1, 485: 0 };
    STACK.forEach(function (id, i) {
      var q = PRS[id], cur = id === state.pr, onPath = STACK.indexOf(id) <= STACK.indexOf(state.pr);
      var pill = q.state === "merged" ? ["Merged", "var(--violet)"] : q.state === "draft" ? ["Draft", "var(--slate)"] : id === 482 ? (state.pushed ? ["Checks running", "var(--amber)"] : ["Changes requested", "var(--red)"]) : ["Ready", "var(--green)"];
      h += '<button class="y-sr' + (cur ? " cur" : "") + (onPath ? " path" : "") + '" data-pr="' + id + '" data-keeptab style="padding-left:' + (10 + i * 22) + 'px!important"><span class="tw">' + icon(i === 0 ? "dotFill" : "turn") + "</span>" + badge(q.state) + '<span class="num">#' + id + '</span><span class="ttl">' + esc(q.title) + "</span>" + (id === 482 && state.agent ? '<span class="tm">' + icon("terminal") + "</span>" : "") + '<span class="y-chip" style="--c:' + (cur ? "var(--violet)" : "var(--slate)") + '">' + q.head + '</span><span class="nb' + (notes[id] ? " has" : "") + '" data-notes="' + id + '">' + icon(notes[id] ? "note" : "notePlus") + (notes[id] ? notes[id] : "") + '</span><span class="y-st" style="--c:' + pill[1] + '">' + pill[0] + "</span></button>";
    });
    h += "</div>";
    if (state.notes) h += notesPopover();
    return h + "</div>";
  }
  function notesPopover() {
    var h = '<div class="y-notes" role="dialog" aria-label="Notes on #482"><h4>Notes on #482<small>Speed up search with debounced queries</small></h4>';
    h += '<div class="y-note"><span class="k"><i style="background:var(--green)"></i>Decision</span><p>Keep the 250 ms delay. Product signed off on it.</p></div>';
    if (state.noteAdded) h += '<div class="y-note' + (state.noteAnim ? " new" : "") + '"><span class="k"><i></i>Note' + icon("terminal") + '</span><p>Stale requests are now aborted in <code>useSearch</code>. #485 picks this up on rebase, no conflicts expected.</p></div>';
    return h + "<footer><span>+ Add note</span><span>Only on this Mac</span></footer></div>";
  }

  function placeholder() {
    return '<div class="y-route"><div class="y-ph"><span class="y-big">' + icon("merge") + "</span><p>Select a pull request, issue or project</p><small>" + mod() + "L to open by link · " + mod() + "K for the command palette</small></div></div>";
  }

  function renderDetail() {
    if (state.section === "agents") { elDet.innerHTML = sessionView(); afterSession(); return; }
    if (state.detail !== "pr") { elDet.innerHTML = placeholder(); return; }
    elDet.innerHTML = prDetail();
    state.rerqAnim = false;
    placeTabUL();
    renderBody();
  }

  function agentList(anim) {
    var a = state.agent, st = agentStatus();
    var h = '<div class="y-alist"><div class="y-acct"><span class="pb">A</span><div><b>alex@example.com</b><small>Team</small></div>' + icon("more") + "</div>";
    h += '<div class="y-ash"><b>Open</b>' + icon("memory") + "<span>" + (a ? "412 MB" : "0 MB") + '</span><span class="lk">Sleep all</span></div>';
    if (a) h += '<button class="y-ses on open' + (a.listAnim ? " new" : "") + '" data-ses="fix"><span>' + FIX_TITLE + '</span><small>web-app</small><span class="y-dot ' + st + '" data-dot></span></button>';
    h += '<div class="y-sdiv"></div><div class="y-phd">' + icon("chevR", "chev") + "<b>web-app</b><small>" + (a ? 3 : 2) + "</small>" + icon("plus") + "</div>";
    if (a) h += '<button class="y-ses' + (a.listAnim ? " new" : "") + '" data-ses="fix"><span>' + FIX_TITLE + "</span>" + icon("pull") + '<span class="y-dot ' + st + '" data-dot></span></button>';
    h += '<button class="y-ses"><span>Saved searches</span>' + icon("pull") + '<span class="y-dot sleep"></span></button><button class="y-ses"><span>Map query params</span><span class="y-dot sleep"></span></button>';
    h += '<div class="y-phd">' + icon("chevR", "chev") + "<b>api</b><small>1</small>" + icon("plus") + '</div><button class="y-ses"><span>Concurrent token refresh</span><span class="y-dot sleep"></span></button>';
    h += '<div class="y-phd">' + icon("chevR", "chev") + "<b>ios</b><small>0</small>" + icon("plus") + "</div></div>";
    if (a) a.listAnim = false;
    return h;
  }

  function sessionView() {
    var a = state.agent;
    if (!a) return '<div class="y-route"><div class="y-ph"><span class="y-big" style="color:var(--coral);background:color-mix(in srgb,var(--coral) 14%,transparent)">' + icon("terminal") + "</span><p>Agents</p><small>Open a pull request and press Fix with agent, or start a session in a folder.</small></div></div>";
    var st = agentStatus();
    var badgeMap = { work: ["bolt", "var(--sky)", "Working"], wait: ["hand", "var(--amber)", "Needs you"], done: ["dotFill", "var(--green)", "Active"], idle: ["dotFill", "var(--green)", "Active"] };
    var b = badgeMap[st];
    var h = '<div class="y-route y-sess"><div class="y-stabs"><span class="y-stab on"><span class="y-dot ' + st + '" data-dot></span><span>' + FIX_TITLE + "</span><small>web-app</small>" + icon("x") + '</span><span class="y-stab"><span class="y-dot sleep"></span><span>Saved searches</span><small>web-app</small></span><span style="color:var(--muted);display:flex;padding:0 4px">' + icon("plus") + "</span></div>";
    h += '<div class="y-ctrl"><b>web-app</b><span class="y-brm">' + icon("branch") + '<span>pullyard/pr-482</span><span class="dm">·</span>' + icon("stack") + '<span>worktree</span><span class="dm">· #482</span>' + icon("chevD") + '</span><span class="y-tsb" data-tsb style="--c:' + b[1] + '">' + icon(b[0]) + b[2] + '<span class="m"> · 412 MB</span></span><span class="sp"></span><span class="mdl">opus</span><span class="y-cseg"><span class="on">' + icon("chatSeg") + "</span><span>" + icon("terminal") + "</span></span>" + '<span class="m" style="display:flex">' + icon("more") + "</span></div>";
    h += '<div class="y-cbody' + (state.inspector ? "" : " noinsp") + '"><div class="y-chatc"><div class="y-msgs"><div class="y-inner">' + a.items.map(function (it) { return chatItem(it, false); }).join("") + (a.busy ? workingHTML() : "") + '</div></div><div class="y-ccomp"><span>' + (a.busy ? "Message will be queued…" : "Ask Claude or describe a task…") + '</span><div class="y-cbar"><span>' + icon("pencil") + 'Accept edits</span><span>' + icon("cpu") + 'Opus</span><span>' + icon("gauge") + "effort</span><span>" + icon("photo") + "</span><span>" + icon("mic") + '</span><span class="sp"></span><span class="y-ring"></span><span class="y-send off">' + icon("up") + "</span></div></div></div>";
    if (state.inspector) h += '<div class="y-insp">' + inspectorHTML() + "</div>";
    return h + "</div></div>";
  }
  var LOGO = '<svg class="y-logo" viewBox="150 370 750 500" aria-hidden="true"><defs><linearGradient id="yHull" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FB7185"/><stop offset="1" stop-color="#D61F4E"/></linearGradient></defs>' +
    '<circle class="lp ln" cx="206" cy="500" r="34" pathLength="1" stroke="#A78BFA" stroke-width="18"/><circle class="lp ln" cx="206" cy="772" r="34" pathLength="1" stroke="#38BDF8" stroke-width="18"/>' +
    '<path class="lp lc" d="M240 500C392 500 420 636 520 636" pathLength="1" stroke="#A78BFA" stroke-width="24"/><path class="lp lc" d="M240 772C392 772 420 636 520 636" pathLength="1" stroke="#38BDF8" stroke-width="24"/>' +
    '<g class="lf"><path d="M470 566H866L800 728H540z" fill="url(#yHull)"/><path d="M470 566H866L857 590H480z" fill="#FECDD3"/><circle cx="770" cy="642" r="15" fill="#FECDD3"/></g>' +
    '<path class="lp lh" d="M470 566H866L800 728H540z" pathLength="1" stroke="#FB7185" stroke-width="14" stroke-linejoin="round"/>' +
    '<g class="lcab"><rect x="702" y="392" width="40" height="86" rx="8" fill="#E2E8F0"/><rect x="702" y="392" width="40" height="20" rx="6" fill="#FB7185"/><rect x="584" y="462" width="176" height="104" rx="16" fill="#F8FAFC"/><rect x="584" y="540" width="176" height="26" fill="#E2E8F0"/><rect x="610" y="488" width="38" height="34" rx="8" fill="#1E293B"/><rect x="664" y="488" width="38" height="34" rx="8" fill="#1E293B"/></g>' +
    '<path class="lp lw1" d="M560 786C620 770 660 802 720 786C780 770 820 770 870 786" pathLength="1" stroke="rgba(125,211,252,.55)" stroke-width="12"/><path class="lp lw2" d="M600 836C650 822 690 848 740 836C790 824 820 822 850 836" pathLength="1" stroke="rgba(125,211,252,.32)" stroke-width="10"/></svg>';
  function workingHTML() { return '<div class="y-work" data-work>' + LOGO + "<span>Working…</span><small data-el>" + (state.agent.elapsed || 0) + "s</small></div>"; }

  function inspectorHTML() {
    var a = state.agent, it = state.itab;
    var edited = a.edited && !a.committed, unpushed = a.committed && !a.pushedDone;
    var running = a.running;
    var h = '<div class="y-itabs"><span class="' + (it === "changes" ? "on" : "") + '">' + icon("plusminus") + "Changes" + (edited ? '<em class="a">1</em>' : "") + '</span><span class="' + (it === "tasks" ? "on" : "") + '">' + icon("terminal") + "Tasks" + (running ? '<em class="s">1</em>' : "") + "</span><span>" + icon("folder") + "Files</span><span>" + icon("pull") + "PR</span></div>";
    if (edited) {
      h += '<div class="y-ihd"><span>1 file changed</span>' + diffStat(3, 1) + '<span class="sp"></span>' + icon("refresh") + '</div><div class="y-ifh">' + icon("chevD") + '<i class="a">M</i><span class="p">src/search/useSearch.ts</span>' + diffStat(3, 1) + '</div><div class="y-idiff">' + AGENT_EDIT.map(function (l) { return lineHTML(l); }).join("") + "</div>";
    } else if (unpushed) {
      h += '<div class="y-ucm"><span>Unpushed commits · 1</span><div><code>b81c0de</code><span>Abort stale search requests</span></div></div>';
    } else {
      h += '<div class="y-ie"><span class="g">' + icon("checkCircle") + "</span>" + (a.pushedDone ? "Working tree clean" : "Changes Claude makes will show up here automatically") + "</div>";
    }
    return h;
  }

  var KINDS = { cmd: ["terminal", "var(--sky)", "Ran", "command", "commands"], read: ["doc", "var(--violet)", "Read", "file", "files"], edit: ["pencil", "var(--coral)", "Edited", "file", "files"], search: ["search", "var(--teal)", "Searched", "pattern", "patterns"] };
  function groupLabel(steps) {
    var counts = {}, order = [];
    ["cmd", "read", "edit", "search"].forEach(function (k) { steps.forEach(function (s) { if (s[0] === k) { if (!counts[k]) { counts[k] = 0; order.push(k); } counts[k]++; } }); });
    var t = order.map(function (k) { var d = KINDS[k]; return d[2].toLowerCase() + " " + counts[k] + " " + (counts[k] === 1 ? d[3] : d[4]); }).join(", ");
    return t.charAt(0).toUpperCase() + t.slice(1);
  }

  function chatItem(it, fresh) {
    var n = fresh ? " y-rise" : "";
    if (it.k === "user") return '<div class="y-um' + n + '">Address the code review feedback on pull request #482 "Speed up search with debounced queries" in acme/web-app.<br><br>1. src/search/useSearch.ts:26 (@sofia)…<span class="more">Show all</span></div>';
    if (it.k === "text") return '<div class="y-ans' + n + '">' + it.text + "</div>";
    if (it.k === "group") {
      var kinds = [];
      it.steps.forEach(function (s) { if (kinds.indexOf(s[0]) < 0) kinds.push(s[0]); });
      var running = it.running;
      var label = running ? "Running: " + it.steps[Math.min(it.progress || 0, it.steps.length - 1)][1] : groupLabel(it.steps);
      var h = '<div class="y-tg' + (it.open ? " open" : "") + n + '" data-g="' + it.id + '"><button class="y-tgh" data-grp="' + it.id + '">' + (running ? '<span class="y-spin s"></span>' : "") + '<span class="kinds">' + kinds.map(function (k) { return '<span style="color:' + KINDS[k][1] + '">' + icon(KINDS[k][0]) + "</span>"; }).join("") + "</span><b>" + esc(label) + "</b>" + icon("chevR") + "</button>";
      if (it.open) h += '<div class="y-tgl">' + it.steps.map(function (s) { return '<div class="y-tr"><span style="color:' + KINDS[s[0]][1] + '">' + icon(KINDS[s[0]][0]) + '</span><span class="t">' + esc(s[1]) + "</span>" + (s[2] ? '<span class="cmd">' + esc(s[2]) + "</span>" : "") + "</div>"; }).join("") + "</div>";
      return h + "</div>";
    }
    if (it.k === "edit") {
      return '<div class="y-tool' + n + '"><div class="y-tr open"><span style="color:var(--coral)">' + icon("pencil") + '</span><span class="t">Edited src/search/useSearch.ts</span>' + diffStat(3, 1) + icon("chevR", "chev") + '</div><div class="y-x"><div class="y-ipath">src/search/useSearch.ts<span>Open</span></div><div class="y-idiff">' + AGENT_EDIT.map(function (l) { return lineHTML(l); }).join("") + "</div></div></div>";
    }
    if (it.k === "perm") {
      return '<div class="y-perm' + n + (it.leaving ? " leave" : "") + '" data-perm><small>Claude wants to run a command</small><span class="ds">Run the search tests</span><div class="y-blk">$ npm test -- search</div><div class="row"><button class="y-btn p lg" data-allow style="--c:var(--accentFill)">Allow</button><span class="sp"></span><kbd>' + mod() + '↩</kbd></div><div class="deny"><span>No — tell Claude what to do instead…</span><button class="y-btn lg" data-deny>Deny</button></div></div>';
    }
    if (it.k === "bash") {
      var h2 = '<div class="y-tool' + n + '"><div class="y-tr open">' + (it.running ? '<span class="y-spin s"></span>' : "") + '<span style="color:var(--sky)">' + icon("terminal") + '</span><span class="t">Run the search tests</span><span class="cmd">npm test -- search</span><span class="sp"></span>' + icon("chevR", "chev") + '</div><div class="y-x"><div class="y-blk">$ npm test -- search</div>';
      if (!it.running) h2 += '<div class="y-blk out y-rise"><span class="ok">✓</span> src/search/useSearch.test.ts (9 tests)\n<span class="ok">✓</span> src/hooks/useDebounce.test.ts (3 tests)\n\n Test Files  2 passed (2)\n      Tests  <span class="ok">12 passed</span> (12)</div>';
      return h2 + "</div></div>";
    }
    if (it.k === "tool") {
      return '<div class="y-tool' + n + '"><div class="y-tr"><span style="color:var(--amber)">' + icon("note") + '</span><span class="t">Added a stack note to #482</span><span class="cmd">pullyard · add_stack_note</span><span class="sp"></span>' + icon("chevR", "chev") + "</div></div>";
    }
    return "";
  }

  function afterSession() {
    scrollChat(true);
  }
  function scrollChat(instant) {
    var box = elDet.querySelector(".y-msgs"), inner = box && box.firstElementChild;
    if (!inner) return;
    var off = Math.max(0, inner.scrollHeight - box.clientHeight);
    if (instant) { inner.style.transition = "none"; inner.style.transform = "translateY(" + -off + "px)"; void inner.offsetWidth; inner.style.transition = ""; }
    else inner.style.transform = "translateY(" + -off + "px)";
  }

  function chatAppend(it) {
    var inner = elDet.querySelector(".y-msgs > .y-inner");
    if (!inner || state.section !== "agents") return;
    var w = inner.querySelector("[data-work]");
    var tmp = document.createElement("div");
    tmp.innerHTML = chatItem(it, true);
    var node = tmp.firstElementChild;
    if (w) inner.insertBefore(node, w); else inner.appendChild(node);
    scrollChat();
  }
  function chatReplace(it) {
    var inner = elDet.querySelector(".y-msgs > .y-inner");
    if (!inner) return;
    var idx = state.agent.items.indexOf(it);
    var nodes = Array.prototype.filter.call(inner.children, function (c) { return !c.hasAttribute("data-work"); });
    var tmp = document.createElement("div");
    tmp.innerHTML = chatItem(it, false);
    if (nodes[idx]) inner.replaceChild(tmp.firstElementChild, nodes[idx]);
    scrollChat();
  }
  function setWorking(on) {
    var inner = elDet.querySelector(".y-msgs > .y-inner");
    if (!inner) return;
    var w = inner.querySelector("[data-work]");
    if (on && !w) { var t = document.createElement("div"); t.innerHTML = workingHTML(); t.firstElementChild.classList.add("y-rise"); inner.appendChild(t.firstElementChild); }
    if (!on && w) w.remove();
    scrollChat();
  }
  function refreshAgentChrome() {
    var st = agentStatus();
    Array.prototype.forEach.call(root.querySelectorAll("[data-dot]"), function (d) { d.className = "y-dot " + st; });
    var tsb = elDet.querySelector("[data-tsb]");
    if (tsb) {
      var m = { work: ["bolt", "var(--sky)", "Working"], wait: ["hand", "var(--amber)", "Needs you"], done: ["dotFill", "var(--green)", "Active"], idle: ["dotFill", "var(--green)", "Active"] }[st];
      tsb.style.setProperty("--c", m[1]);
      tsb.innerHTML = icon(m[0]) + m[2] + '<span class="m"> · 412 MB</span>';
    }
    var insp = elDet.querySelector(".y-insp");
    if (insp) insp.innerHTML = inspectorHTML();
    var cs = elDet.querySelector(".y-ccomp > span");
    if (cs) cs.textContent = state.agent.busy ? "Message will be queued…" : "Ask Claude or describe a task…";
    updateSidebar();
  }

  var timers = [];
  function later(fn, ms) { var t = setTimeout(fn, ms); timers.push(t); return t; }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }

  function runAgent() {
    var a = state.agent;
    if (!a || a.waiting || a.step >= SCRIPT.length) return;
    var step = SCRIPT[a.step];
    a.busy = true;
    later(function () {
      a.step++;
      if (step.k === "user") { var u = { k: "user" }; a.items.push(u); chatAppend(u); setWorking(true); refreshAgentChrome(); runAgent(); return; }
      if (step.k === "group") {
        var g = { k: "group", id: step.id, steps: step.steps, running: true, progress: 0, open: false };
        a.items.push(g); chatAppend(g);
        var i = 0;
        (function tick() {
          i++;
          if (i < step.steps.length) { g.progress = i; chatReplace(g); later(tick, 420 * pace); return; }
          later(function () {
            g.running = false; chatReplace(g);
            if (step.push) { a.committed = true; a.pushedDone = true; onPushed(); }
            refreshAgentChrome(); runAgent();
          }, 420 * pace);
        })();
        if (step.push) later(function () { a.committed = true; refreshAgentChrome(); }, 420 * pace);
        return;
      }
      if (step.k === "edit") { var e = { k: "edit" }; a.items.push(e); chatAppend(e); a.edited = true; refreshAgentChrome(); runAgent(); return; }
      if (step.k === "perm") {
        var pm = { k: "perm" }; a.items.push(pm); chatAppend(pm);
        a.waiting = true; a.busy = false; setWorking(false); refreshAgentChrome();
        if (state.section !== "agents") notify(FIX_TITLE, "Your agent needs permission: Bash");
        return;
      }
      if (step.k === "bash") {
        var b = { k: "bash", running: true }; a.items.push(b); chatAppend(b); a.running = true; refreshAgentChrome();
        later(function () { b.running = false; a.running = false; chatReplace(b); refreshAgentChrome(); runAgent(); }, step.run * pace);
        return;
      }
      if (step.k === "tool") { var tl = { k: "tool" }; a.items.push(tl); chatAppend(tl); state.noteAdded = true; state.noteAnim = true; runAgent(); return; }
      if (step.k === "text") {
        var tx = { k: "text", text: step.text }; a.items.push(tx); chatAppend(tx);
        if (step.final) {
          a.busy = false; a.done = true; a.seen = state.section === "agents"; setWorking(false); refreshAgentChrome();
          if (!a.seen) notify("Agent finished · " + FIX_TITLE, "Done. Each query now aborts the previous request…");
          return;
        }
        runAgent();
      }
    }, reduced() ? Math.min(step.d, 250) : step.d * pace);
  }

  function onPushed() {
    state.pushed = true;
    var p = PRS[482];
    p.ci = "run"; p.review = "req"; p.ago = "just now";
    p.checks = p.checks.map(function (c) { return c[1] === "CI / lint" ? c : ["run", c[1], "running"]; });
    PRS[482].files[0].lines = USE_SEARCH_NEW;
    if (state.rerq !== "gone") state.rerq = "show";
    later(function () { p.checks = p.checks.map(function (c) { return c[0] === "run" ? ["ok", c[1], c[1] === "e2e / chrome" ? "3m 31s" : "52s"] : c; }); p.ci = "ok"; }, 9000);
  }

  function allow() {
    var a = state.agent;
    if (!a || !a.waiting) return;
    var pm = a.items[a.items.length - 1];
    var node = elDet.querySelector("[data-perm]");
    a.waiting = false;
    function cont() {
      a.items.splice(a.items.indexOf(pm), 1);
      if (node) node.remove();
      setWorking(true); refreshAgentChrome(); runAgent();
    }
    if (node && !reduced()) { node.classList.add("leave"); later(cont, 200); } else cont();
  }
  function deny() {
    var a = state.agent;
    if (!a || !a.waiting) return;
    a.waiting = false; a.busy = false; a.done = true; a.seen = true; a.step = SCRIPT.length;
    var pm = a.items[a.items.length - 1];
    a.items.splice(a.items.indexOf(pm), 1);
    var t = { k: "text", text: "Okay, I won't run the tests. Tell me what to do instead." };
    a.items.push(t);
    renderDetail(); refreshAgentChrome();
  }

  function notify(title, body) {
    state.toast = { title: title, body: body };
    var old = root.querySelector(".y-toast");
    if (old) old.remove();
    var b = document.createElement("button");
    b.className = "y-toast";
    b.setAttribute("data-ses", "fix");
    b.innerHTML = '<img src="icon-512.png" alt=""><div><small>PULLYARD</small><b>' + esc(title) + "</b><p>" + esc(body) + "</p></div>";
    root.appendChild(b);
    later(function () { b.classList.add("leave"); later(function () { b.remove(); }, 200); }, 5000);
  }

  function openSheet() {
    if (state.sheet) return;
    state.sheet = true;
    var bg = document.createElement("div");
    bg.className = "y-sheetbg";
    bg.innerHTML = '<div class="y-sheet" role="dialog" aria-label="Fix with agent"><div class="y-shh"><span class="y-sq" style="--c:var(--coral)">' + icon("wrench") + '</span><div><b>Fix with agent</b><small><i>#482</i> Speed up search with debounced queries</small></div></div>' +
      segHTML("src", [["comments", "Build from comments (1)"], ["checks", "Failing checks (0)"]], "comments", "sm mute") +
      '<div class="y-cl"><div class="hd"><b style="font-weight:600">Unresolved comments</b><span>All · None</span></div><span class="y-cb"><i>' + icon("check") + '</i><span><code>src/search/useSearch.ts:26</code> @sofia: Cancel the in-flight request when the query changes…</span></span></div>' +
      '<div class="y-opts"><span class="y-cb"><i>' + icon("check") + '</i>Commit</span><span class="y-cb"><i>' + icon("check") + '</i>Push</span><span class="y-cb"><i class="off"></i>Reply &amp; resolve threads</span></div>' +
      '<div class="y-pv"><div class="hd"><span>Prompt</span><span>' + PROMPT.length + ' characters</span></div><pre>' + esc(PROMPT) + "</pre></div>" +
      '<div class="y-fold">' + icon("folderFill") + "<code>~/code/web-app</code></div>" +
      '<div class="y-wt"><span class="y-cb"><i>' + icon("check") + '</i>Work in an isolated git worktree</span><small>Creates ~/code/web-app-worktrees/pr-482 on branch pullyard/pr-482 at the pull request head</small></div>' +
      '<div class="y-shf"><span class="pk">Open in <span>In this app</span></span><span class="pk">Mode <span>Accept edits</span></span><span class="sp"></span><button class="y-btn lg" data-cancel>Cancel</button><button class="y-btn p lg" data-launch style="--c:var(--coral)">Launch</button></div></div>';
    root.appendChild(bg);
    placeSegs(bg);
  }
  function closeSheet(cb) {
    var bg = root.querySelector(".y-sheetbg");
    state.sheet = false;
    if (!bg) { if (cb) cb(); return; }
    bg.classList.add("leave");
    later(function () { bg.remove(); if (cb) cb(); }, reduced() ? 0 : 170);
  }
  function launch() {
    closeSheet(function () {
      state.agent = { step: 0, items: [], busy: true, waiting: false, done: false, seen: true, listAnim: true, elapsed: 0 };
      state.section = "agents"; state.showDetail = true; state.itab = "changes";
      renderAll(true);
      runAgent();
    });
  }

  function select(id) {
    if (state.section === id) return;
    state.section = id;
    state.notes = false;
    var s = sec(id);
    if (s.list) { state.filter = "open"; if (s.list.indexOf(state.pr) < 0) state.detail = null; else state.detail = "pr"; }
    else if (id !== "notifications" && id !== "stacks") state.detail = null;
    if (id === "agents") { state.showDetail = !!state.agent; if (state.agent && state.agent.done) state.agent.seen = true; }
    else state.showDetail = false;
    renderAll(true);
  }
  function openPR(id, tab) {
    var same = state.detail === "pr" && state.pr === id;
    if (state.section === "agents") state.section = "mine";
    state.pr = id; state.detail = "pr"; state.showDetail = true; state.notes = false; state.convScroll = 0;
    state.tab = tab || (same ? state.tab : "conversation"); state.file = 0;
    root.classList.toggle("show-detail", true);
    updateListSelection(); updateSidebar(); renderToolbar();
    if (!same) renderDetail();
    else { refreshTabs(); renderBody(); }
  }
  function setTab(t) {
    if (state.tab === t) return;
    state.tab = t; state.notes = false;
    var on = elDet.querySelector(".y-tabs .on"), nb = elDet.querySelector('.y-tabs [data-tab="' + t + '"]');
    if (on) on.classList.remove("on");
    if (nb) nb.classList.add("on");
    placeTabUL();
    renderBody();
  }

  function reRequest() {
    if (state.rerq !== "show") return;
    state.rerq = "sending"; renderBanners();
    later(function () {
      state.rerq = "done"; state.rerqAnim = true; renderBanners();
      if (state.tab === "conversation") renderBody();
      later(function () {
        var n = elDet.querySelector('[data-bnr="rerq"]');
        function gone() { state.rerq = "gone"; renderBanners(); }
        if (n && !reduced()) { n.classList.add("y-out"); later(gone, 200); } else gone();
      }, 2500);
    }, 650);
  }

  function arriveNewPR() {
    var s = sec("review");
    if (s.list.indexOf(91) >= 0) return;
    s.list.unshift(91);
    state.reviewCount = 4;
    updatedAt = Date.now();
    updateSidebar();
    if (state.section === "review" && !state.palette) {
      var rows = elList.querySelector(".y-rows");
      if (rows && state.filter !== "closed") {
        var t = document.createElement("div");
        t.innerHTML = prRow(91, "y-fresh");
        rows.insertBefore(t.firstElementChild, rows.firstChild);
      }
      renderToolbar();
    }
  }

  function renderAll(anim) {
    root.className = "demo os-" + platform() + (state.showDetail ? " show-detail" : "");
    renderToolbar(); updateSidebar(); renderList(anim); renderDetail();
  }

  root.addEventListener("click", function (e) {
    var t = e.target.closest("button,[data-palette],[data-notes]");
    if (!t || !root.contains(t)) return;
    var d = t.dataset;
    if (d.notes !== undefined && d.notes) { e.stopPropagation(); if (+d.notes === 482) { state.notes = !state.notes; state.noteAnim = false; renderBody(); } return; }
    if (d.sec) select(d.sec);
    else if (d.ses !== undefined) { var to = root.querySelector(".y-toast"); if (to) to.remove(); if (state.section !== "agents") select("agents"); }
    else if (d.pr) openPR(+d.pr, d.tabgo || (t.hasAttribute("data-keeptab") ? state.tab : null));
    else if (d.filter) { state.filter = d.filter; renderToolbar(); renderList(true); }
    else if (d.mode) { state.diffMode = d.mode; renderBody(); }
    else if (d.tab) setTab(d.tab);
    else if (d.file) { state.file = +d.file; renderBody(); }
    else if (t.hasAttribute("data-rerq")) reRequest();
    else if (t.hasAttribute("data-fix")) openSheet();
    else if (t.hasAttribute("data-cancel")) closeSheet();
    else if (t.hasAttribute("data-launch")) launch();
    else if (t.hasAttribute("data-allow")) allow();
    else if (t.hasAttribute("data-deny")) deny();
    else if (t.hasAttribute("data-back")) { state.showDetail = false; root.classList.remove("show-detail"); }
    else if (t.hasAttribute("data-insp")) { state.inspector = !state.inspector; renderDetail(); }
    else if (t.hasAttribute("data-refresh")) { updatedAt = Date.now(); Array.prototype.forEach.call(root.querySelectorAll("[data-ago]"), function (x) { x.textContent = agoShort(); }); }
    else if (d.grp) { var g = state.agent && state.agent.items.filter(function (x) { return x.id === d.grp; })[0]; if (g) { g.open = !g.open; chatReplace(g); } }
    else if (t.hasAttribute("data-palette")) openPalette();
    else if (d.cmd !== undefined) runCommand(+d.cmd);
  });
  root.addEventListener("click", function (e) {
    if (e.target.classList && e.target.classList.contains("y-sheetbg")) closeSheet();
    if (e.target.classList && e.target.classList.contains("y-pal-bg")) closePalette();
  });

  function commands() {
    var list = [];
    SECTIONS.forEach(function (s) { if (s.id) list.push({ g: "Go to", t: s.title, run: function () { select(s.id); } }); });
    [482, 485, 480, 58, 479, 213, 470].forEach(function (id) { list.push({ g: "Pull requests", t: PRS[id].title, d: PRS[id].repo + "#" + id, run: function () { openPR(id); } }); });
    list.push({ g: "Actions", t: "Fix with agent", d: "#482", run: function () { openPR(482); openSheet(); } });
    return list;
  }
  function filtered() {
    var q = state.palette.q.toLowerCase().trim();
    return commands().filter(function (c) { return !q || (c.t + " " + (c.d || "") + " " + c.g).toLowerCase().indexOf(q) >= 0; });
  }
  function paletteList() {
    var items = filtered(), g = null, h = "";
    if (!items.length) return '<div class="y-empty">No matches</div>';
    state.palette.sel = Math.max(0, Math.min(state.palette.sel, items.length - 1));
    items.forEach(function (c, i) {
      if (c.g !== g) { g = c.g; h += '<div class="y-pal-g">' + g + "</div>"; }
      h += '<button class="y-pal-it' + (i === state.palette.sel ? " on" : "") + '" data-cmd="' + i + '"><span></span><span>' + esc(c.t) + "</span>" + (c.d ? "<small>" + c.d + "</small>" : "") + "</button>";
    });
    return h;
  }
  function openPalette() {
    if (state.palette) return;
    state.palette = { q: "", sel: 0 };
    var bg = document.createElement("div");
    bg.className = "y-pal-bg";
    bg.innerHTML = '<div class="y-pal" role="dialog" aria-label="Command palette"><div class="y-pal-in">' + icon("search") + '<input data-pal-q placeholder="Go to, open a pull request or run a command" aria-label="Search commands"><kbd>esc</kbd></div><div class="y-pal-list">' + paletteList() + "</div></div>";
    root.appendChild(bg);
    var q = bg.querySelector("input");
    q.focus({ preventScroll: true });
    q.addEventListener("input", function () { state.palette.q = q.value; state.palette.sel = 0; bg.querySelector(".y-pal-list").innerHTML = paletteList(); });
  }
  function closePalette() { state.palette = null; var bg = root.querySelector(".y-pal-bg"); if (bg) bg.remove(); }
  function runCommand(i) { var c = filtered()[i]; closePalette(); if (c) c.run(); }

  var hovering = false;
  root.addEventListener("pointerenter", function () { hovering = true; });
  root.addEventListener("pointerleave", function () { hovering = false; });
  document.addEventListener("keydown", function (e) {
    if (!hovering && !root.contains(document.activeElement)) return;
    var k = (e.key || "").toLowerCase();
    if (state.palette) {
      if (k === "escape") { e.preventDefault(); closePalette(); }
      else if (k === "arrowdown" || k === "arrowup") { e.preventDefault(); state.palette.sel += k === "arrowdown" ? 1 : -1; root.querySelector(".y-pal-list").innerHTML = paletteList(); }
      else if (k === "enter") { e.preventDefault(); runCommand(state.palette.sel); }
      return;
    }
    if ((e.metaKey || e.ctrlKey) && k === "k") { e.preventDefault(); openPalette(); return; }
    if ((e.metaKey || e.ctrlKey) && k === "enter" && state.agent && state.agent.waiting) { e.preventDefault(); allow(); return; }
    if (k === "escape" && state.sheet) { closeSheet(); return; }
    if (/input|textarea/i.test((document.activeElement || {}).tagName || "") || e.metaKey || e.ctrlKey || e.altKey) return;
    if (state.section !== "agents" && state.detail === "pr" && state.tab === "files" && (k === "j" || k === "k")) {
      var n = PRS[state.pr].files.length;
      state.file = Math.max(0, Math.min(n - 1, state.file + (k === "j" ? 1 : -1)));
      renderBody();
    }
  });

  setInterval(function () {
    Array.prototype.forEach.call(root.querySelectorAll("[data-ago]"), function (x) { var v = agoShort(); if (x.textContent !== v) x.textContent = v; });
    if (state.agent && state.agent.busy) {
      state.agent.elapsed = (state.agent.elapsed || 0) + 1;
      var el = root.querySelector("[data-el]");
      if (el) el.textContent = state.agent.elapsed + "s";
    }
  }, 1000);

  document.addEventListener("platformchange", function () { renderAll(false); });

  var cur = { x: 0, y: 0, shown: false };
  var pace = 1;
  function wait(ms) { return sleep(ms * pace); }
  var touring = false, tourToken = 0;
  function sleep(ms) { var tok = tourToken; return new Promise(function (res, rej) { later(function () { tok === tourToken ? res() : rej("stop"); }, ms); }); }
  function q(sel) { return root.querySelector(sel); }
  function pointAt(el, ax, ay) {
    var r = root.getBoundingClientRect(), b = el.getBoundingClientRect();
    return { x: b.left - r.left + b.width * (ax == null ? 0.5 : ax), y: b.top - r.top + b.height * (ay == null ? 0.5 : ay) };
  }
  function moveCursor(p, ms) {
    elCur.classList.add("on");
    var dist = Math.hypot(p.x - cur.x, p.y - cur.y);
    var dur = ms || Math.round(Math.min(900, Math.max(380, dist * 1.1)));
    elCur.style.transition = cur.shown ? "transform " + dur + "ms cubic-bezier(.45,.05,.25,1), opacity .25s ease-out" : "opacity .25s ease-out";
    elCur.style.transform = "translate(" + p.x + "px," + p.y + "px)";
    var first = !cur.shown;
    cur.x = p.x; cur.y = p.y; cur.shown = true;
    return sleep(first ? 250 : dur + 60);
  }
  function click(sel, ax, ay) {
    var el = typeof sel === "string" ? q(sel) : sel;
    if (!el) return sleep(10);
    return moveCursor(pointAt(el, ax, ay)).then(function () {
      elCur.classList.add("down");
      el.classList.add("press");
      return sleep(110);
    }).then(function () {
      elCur.classList.remove("down");
      elCur.classList.remove("click"); void elCur.offsetWidth; elCur.classList.add("click");
      el.classList.remove("press");
      el.click();
      return sleep(120);
    });
  }
  function hover(sel, ax, ay, ms) {
    var el = q(sel);
    if (!el) return sleep(10);
    return moveCursor(pointAt(el, ax, ay), ms);
  }
  function scrollConv(px) {
    state.convScroll = px;
    var inner = elDet.querySelector(".y-scroll > .y-inner");
    if (inner) inner.style.transform = "translateY(" + -px + "px)";
  }
  function waitFor(fn, step) { return sleep(step || 100).then(function () { return fn() ? null : waitFor(fn, step); }); }

  var MARKS = [];
  function mark(name) { MARKS.push([name, Date.now()]); if (window.__demoMark) window.__demoMark(name); }

  function reset() {
    tourToken++;
    clearTimers();
    initState();
    sec("review").list = [479, 470, 213];
    PRS[482].ci = "ok"; PRS[482].review = "changes"; PRS[482].ago = "2h";
    PRS[482].checks = [["ok", "CI / build", "1m 12s"], ["ok", "CI / unit tests", "48s"], ["ok", "CI / lint", "21s"], ["ok", "e2e / chrome", "3m 40s"]];
    PRS[482].files[0].lines = USE_SEARCH_OLD;
    state.noteAdded = false;
    lastPos = {};
    updatedAt = Date.now();
    var t = root.querySelector(".y-toast"); if (t) t.remove();
    var s = root.querySelector(".y-sheetbg"); if (s) s.remove();
    elCur.classList.remove("on"); cur.shown = false;
    renderSidebar(); renderAll(false);
  }

  function tour(opts) {
    opts = opts || {};
    reset();
    touring = true;
    MARKS = [];
    state.inspector = !!opts.inspector;
    pace = opts.pace || 1;
    state.section = "mine"; state.detail = null; state.showDetail = false;
    renderAll(true);
    var c0 = pointAt(elDet, 0.6, 0.55);
    cur.x = c0.x; cur.y = c0.y;
    elCur.style.transform = "translate(" + c0.x + "px," + c0.y + "px)";
    mark("start");
    return wait(700)
      .then(function () { return moveCursor(c0); })
      .then(function () { mark("open-pr"); return click('.y-list [data-pr="482"]', 0.35, 0.3); })
      .then(function () { return wait(900); })
      .then(function () { mark("banner"); return hover('[data-rerq]', 0.5, 0.5); })
      .then(function () { return wait(500); })
      .then(function () { mark("rerq-click"); return click("[data-rerq]"); })
      .then(function () { return wait(1500); })
      .then(function () { mark("requested"); return wait(1600); })
      .then(function () { mark("to-review"); return click('[data-sec="review"]', 0.3, 0.5); })
      .then(function () { return wait(1100); })
      .then(function () { mark("new-pr"); arriveNewPR(); return wait(2600); })
      .then(function () { mark("back-mine"); return click('[data-sec="mine"]', 0.3, 0.5); })
      .then(function () { return wait(500); })
      .then(function () { return click('.y-list [data-pr="482"]', 0.35, 0.3); })
      .then(function () { return wait(700); })
      .then(function () { mark("fix-click"); return click('[data-bnr="fix"] [data-fix]'); })
      .then(function () { mark("sheet"); return wait(1400); })
      .then(function () { return hover("[data-launch]", 0.5, 0.5); })
      .then(function () { return wait(300); })
      .then(function () { mark("launch"); return click("[data-launch]"); })
      .then(function () { var c1 = pointAt(elDet, 0.82, 0.5); return moveCursor(c1, 700); })
      .then(function () { mark("chat"); return waitFor(function () { return state.agent && state.agent.waiting; }); })
      .then(function () { mark("perm"); return wait(1200); })
      .then(function () { return click("[data-allow]"); })
      .then(function () { mark("allowed"); return waitFor(function () { return state.agent.items.some(function (i) { return i.k === "bash" && !i.running; }); }); })
      .then(function () { mark("tests-pass"); return waitFor(function () { return state.agent.done; }); })
      .then(function () { mark("done"); return wait(1800); })
      .then(function () { mark("back-pr"); return click('[data-sec="mine"]', 0.3, 0.5); })
      .then(function () { return wait(500); })
      .then(function () { return click('.y-list [data-pr="482"]', 0.35, 0.3); })
      .then(function () { mark("pr-after"); return wait(1500); })
      .then(function () { mark("files"); state.flashNew = true; return click('[data-tab="files"]'); })
      .then(function () { state.flashNew = false; return wait(2600); })
      .then(function () { mark("stack"); return click('[data-tab="stack"]'); })
      .then(function () { return wait(900); })
      .then(function () { return click('[data-notes="482"]'); })
      .then(function () { mark("notes"); return wait(3200); })
      .then(function () { mark("end"); elCur.classList.remove("on"); touring = false; pace = 1; return MARKS; })
      .catch(function () { pace = 1; touring = false; elCur.classList.remove("on"); return MARKS; });
  }

  function stopTour() { if (touring) { tourToken++; touring = false; elCur.classList.remove("on"); } }
  root.addEventListener("pointerdown", function (e) { if (e.isTrusted) stopTour(); }, true);
  root.addEventListener("keydown", function (e) { if (e.isTrusted) stopTour(); }, true);

  window.PullYardDemo = { tour: tour, reset: reset, stop: stopTour, arriveNewPR: arriveNewPR, state: function () { return state; }, marks: function () { return MARKS; } };

  renderSidebar();
  renderAll(true);
  var userTouched = false;
  root.addEventListener("pointerdown", function (e) { if (e.isTrusted) userTouched = true; }, true);
  if (!/[?&]notimers/.test(location.search)) {
    setTimeout(function () { if (!touring && !userTouched) arriveNewPR(); }, 8000);
    if ("IntersectionObserver" in window && !reduced()) {
      var io = new IntersectionObserver(function (entries) {
        if (!entries[0].isIntersecting) return;
        io.disconnect();
        setTimeout(function () { if (!userTouched && !touring) tour(); }, 1200);
      }, { threshold: 0.6 });
      io.observe(root);
    }
  }
})();
