const SCREENS = {
  "main-small": { title: "Main window — small (1024×680)", file: "main-small-dark", notes: ["Sidebar collapses to a 60 pt icon rail below 1180 pt, with tooltips and count badges", "List column capped at 320 pt so the detail keeps room", "Account menu and Settings stay reachable in the rail"] },
  "main": { title: "Main window — laptop (1380×860)", file: "main-laptop-light", notes: ["List subtitle reads “3 results” instead of a bare number", "Empty detail hints at ⌘L and ⌘K", "Sidebar rows are real buttons (keyboard and VoiceOver)", "Dim text contrast raised to ≥3.7:1"] },
  "pr-detail": { title: "PR details — laptop", file: "pr-detail-dark", notes: ["One Refresh control (status pill is now clickable); duplicate hidden-tab Refresh buttons removed", "State badge uses a dark fill: white text ≥4.5:1 in dark mode", "Merge button is neutral (not grey-green) when blocked, tooltip says why", "Fix with agent hidden on merged/closed PRs"] },
  "diff": { title: "Diff viewer — laptop", file: "diff-light", notes: ["C / ⇧C jump between comment threads (shown when threads exist)", "V marks viewed and advances to the next file", "Inline drafts survive scrolling and table reloads", "Diff lines readable by VoiceOver, with a “Comment on line” action"] },
  "diff-small": { title: "Diff viewer — small window", file: "diff-small-dark", notes: ["Tabs no longer wrap mid-word (“Conversa-tion”): icon-only fallback", "Open badge no longer truncated to “…”", "Icon rail frees 160 pt for the diff"] },
  "merge-sheet": { title: "Merge sheet", file: "merge-sheet-light", notes: ["Readiness shown in the sheet (“Has conflicts with main”)", "Primary button reads “Merge anyway” and turns red when GitHub reports a block", "Errors appear inside the sheet instead of a hidden alert behind it", "Failed branch delete after merge is reported"] },
  "review-sheet": { title: "Review / comments", file: "review-sheet-dark", notes: ["Inline error row inside the sheet", "Discard pending comments asks first", "Approve from the toolbar says “Approve and submit N pending comments?”", "Reply and resolve in one step on inline threads"] },
  "settings": { title: "Settings", file: "settings-light", notes: ["12-section scroll split into General / Accounts / Integrations / Advanced tabs", "GitHub-only OAuth client ID moved to Advanced and labelled", "Last selected tab is remembered"] },
  "agents": { title: "Claude Code workspace (session list blurred for privacy)", file: "agents-dark", blur: true, notes: ["Closing a working or waiting agent asks before stopping it", "Session tabs and rows expose name, project and state to VoiceOver", "State dots get tooltips (Working / Needs you / Sleeping)", "Workspace and authentication unchanged"] }
};
const q = new URLSearchParams(location.search);
const key = q.get("screen") || "main";
const base = "../../screenshots/macos/";
function pair(s, small) {
  const blur = s.blur ? " blur" : "";
  return `<div class="pair ${small ? "small" : ""}"><figure><figcaption><span class="tag before">Before</span> main</figcaption><div class="img${blur}"><img src="${base}before/${s.file}.png"></div></figure><figure><figcaption><span class="tag after">After</span> ux-overhaul</figcaption><div class="img${blur}"><img src="${base}after/${s.file}.png"></div></figure></div>`;
}
if (key === "overview") {
  document.body.classList.add("overview");
  document.body.innerHTML = `<header><h1>PullYard macOS — UX overhaul, before vs after</h1><p>Real screenshots of the running app: left = main branch build, right = ux-overhaul build. Demo mode on pullyard/pullyard.</p></header>` +
    Object.values(SCREENS).map(s => `<section><h2>${s.title}</h2>${pair(s, true)}<ul>${s.notes.slice(0, 2).map(n => `<li>${n}</li>`).join("")}</ul></section>`).join("");
} else {
  const s = SCREENS[key];
  document.body.innerHTML = `<header><h1>${s.title}</h1><p>Real screenshots of the running macOS app · left: main · right: ux-overhaul</p></header>${pair(s)}<ol class="callouts">${s.notes.map(n => `<li>${n}</li>`).join("")}</ol>`;
}
