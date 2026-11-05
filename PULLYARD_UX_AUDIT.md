# PullYard UX Audit

Branch `ux-overhaul` · audit date 2026-11-03 · macOS app 2.13.6 (`Sources/`), Linux GTK 4 port (`linux/`), Windows WinUI 3 port (`windows/`).

## How this audit was done

- Six read-only audit agents ran in parallel, each with one scope: UX/product, visual design + design system, desktop platforms, Git providers, accessibility + interaction, diff viewer + review workflow. A seventh agent (QA) reviewed the finished diff independently. The orchestrator merged duplicate findings, resolved conflicts and did all edits sequentially.
- The macOS app was built from `main`, packaged as a separate bundle (`PullYard UX Before`, bundle id `dev.vaache.shipyard.uxbefore`) and run in demo mode against the public `pullyard/pullyard` repository. Screenshots were taken at 1024×680, 1380×860 and 1800×1100, in light and dark (`docs/ux-overhaul/screenshots/macos/before/`).
- Linux and Windows could not be run on this Mac (no GTK runtime, no .NET/WinUI). They were audited from source only.

Priority key: **P0** breaks a workflow or misleads the user · **P1** clear friction or a missing state · **P2** polish.
Status key: ✅ fixed in this branch · 🟡 partly fixed · ⏭ deferred (see `PULLYARD_UX_ROADMAP.md`).

## Major problems found (summary)

1. **Small windows break the layout (P0).** At 1024 pt the fixed 220 pt sidebar plus 360 pt list leave about 340 pt for the PR. Tab labels wrap mid-word ("Conversa-tion", "Chec ks", "Files chang ed"), the PR state badge shrinks to "…", and the sidebar text clips ("lex Rivera"). See `docs/ux-overhaul/comparison/diff-small.png`.
2. **Errors happen out of sight (P0).** Failed merge/review/edit/reply errors went to an alert attached to the view *behind* the sheet. The toast always showed a green check, even for account-switch errors, and vanished after 1.8 s.
3. **Unsafe review/merge flows (P1).** The quick toolbar "Approve" silently submitted pending inline comments. The merge sheet didn't show readiness and offered a normal green "Merge" for a conflicting PR. "Discard pending comments" deleted with one click. A failed branch delete after merge was swallowed.
4. **Lost review work in the diff (P0).** Inline comment and reply drafts lived in reused table cells, so scrolling away or a refresh erased them.
5. **Decorative or duplicated controls (P1).** The PR toolbar showed a refresh icon that was not clickable, plus 2–3 extra Refresh buttons registered by hidden tabs. "Request review" appeared three times and "Open in browser" twice. "Fix with agent" showed on merged PRs.
6. **Provider dead ends (P1).** ⌘L "Open by link" did nothing on GitLab/Bitbucket/Gitea accounts. The Go menu said "My Pull Requests" and "Projects" (a GitHub-only screen) on GitLab.
7. **Silent failures (P1).** Notifications were marked read/done locally even when the API failed. Infinite scroll stopped silently on a page error. The job log spun forever for checks without a job id.
8. **Accessibility gaps (P0/P1).** Diff lines were invisible to VoiceOver. Sidebar and Agents rows were tap-gesture only. Tab badges such as "✕1" were read as "multiplication x 1". State dots were colour-only. `syDim` text measured 2.4–2.8:1. White text on the dark-mode state colours measured 2.3–2.9:1.
9. **One long Settings form (P2).** Twelve sections in a single 500 pt scroll, with a GitHub-only OAuth client ID field between user preferences.
10. **Windows feels like a port (P0/P1, not run).** Window size ignores DPI (at 150% it opens below the intended minimum and the nav collapses to a rail), there is an opaque 36 px title band over Mica, macOS point sizes are reused (13 px body), and shortcuts die while a WebView has focus.

## Findings by area

Each finding: screen · source · problem → user impact → fix · status.

### A. Application shell

| # | P | Screen · source | Problem → impact | Fix · status |
|---|---|---|---|---|
| A1 | P0 | Main window · `App/RootView.swift` `AppShell` | Fixed 220 pt sidebar at every width → PR detail unreadable below about 1200 pt | Icon rail (60 pt) below 1180 pt with tooltips, count badges, account menu and Settings; list capped at 320 pt in compact mode · ✅ |
| A2 | P2 | Toolbar · `SidebarToggleButton` | No shortcut to hide the sidebar | ⌃⌘S, label and tooltip reflect state · ✅ |
| A3 | P1 | Sidebar · `SidebarRow` | `.onTapGesture` row: no keyboard or VoiceOver activation | Real `Button` with selected trait, label and value · ✅ |
| A4 | P1 | Sidebar footer · `AccountSwitcherFooter` | Hidden when the app starts offline without a cached user → no sign-out or switch | Falls back to `app.account` · ✅ |
| A5 | P0 | Global toast · `Shared/ShortLink.swift`, `AppModel.showToast` | Errors shown with a green check, 1 line, 1.8 s, not announced | `showToast(_:isError:)`: red warning icon, 3 lines, 5 s, VoiceOver announcement for every toast · ✅ |
| A6 | P2 | Empty detail | Hint only for ⌘L, in `syDim` | "⌘L to open by link · ⌘K for the command palette" in `syMuted` · ✅ |

### B. Repository and list experience

| # | P | Screen · source | Problem → impact | Fix · status |
|---|---|---|---|---|
| B1 | P1 | All PR/issue lists · `SearchListView.swift` `loadMore` | `try?` → list looks complete when page 2 failed | "Couldn't load more results · Retry" row; cleared on reload or new query · ✅ |
| B2 | P2 | List subtitle | Bare number "3" | "3 results" · ✅ |
| B3 | P2 | Lists | Sort is hard-coded (`sort:updated-desc`); Open/Closed/All resets on section switch | Sort menu + persisted state filter · ⏭ |
| B4 | P1 | Notifications · `NotificationsView.swift` | Read/Done/Mark all changed local state even on API failure | Local state changes only on success; explicit actions show an error toast; read-on-select stays quiet · ✅ |
| B5 | P2 | Notifications | Done/read only in the context menu | Hover action · ⏭ |

### C. Pull request experience

| # | P | Screen · source | Problem → impact | Fix · status |
|---|---|---|---|---|
| C1 | P1 | PR toolbar · `PRDetailView.swift` | Refresh status looked like a button but wasn't one; hidden tabs added duplicate Refresh buttons | Status pill is the single refresh button (⌘R); tab-level buttons removed (`liveRefresh(button: false)`) · ✅ |
| C2 | P2 | PR toolbar / More menu | Duplicate "Request review" and "Open in browser"; "Fix with agent" on merged/closed PRs | Duplicates removed from More; Fix shown only for open PRs · ✅ |
| C3 | P0 | PR header · `StateBadge` | White on light dark-mode hues 2.3–2.9:1; badge truncated to "…" in narrow windows | Dark `*Fill` tokens (≥4.5:1 in both modes), `fixedSize` · ✅ |
| C4 | P2 | Merge status bar | Draft says "merging is unavailable" with no way out | "Ready for review" button in the bar (draft + `viewerCanUpdate`) · ✅ |
| C5 | P2 | Ad-hoc actions | Convert to draft, update branch, reopen gave no feedback | Success toasts · ✅ |
| C6 | P2 | Checks tab badge | "✕1" read as "multiplication x 1" | `TabItem.badgeLabel` ("1 failing") · ✅ |

### D. Diff viewer

| # | P | Area · source | Problem → impact | Fix · status |
|---|---|---|---|---|
| D1 | P0 | Inline composer/replies · `FilesTab.swift` | Drafts in `@State` of reused cells → lost on scroll/reload | `PRDetailModel.composerDraft` / `replyDrafts`; discard confirmation; opening another line keeps the current draft and points to it · ✅ |
| D2 | P1 | Navigation · `DiffTableView.swift` | No way to jump between comment threads | `C` / `⇧C`, plus buttons in the review bar when non-outdated threads exist · ✅ |
| D3 | P2 | Viewed flow | `V` collapsed the file but stayed on it | `V` marks viewed and moves to the next file (unmarking stays put) · ✅ |
| D4 | P1 | Viewed toggle · `PRDetailModel.toggleViewed` | Optimistic state not rolled back on failure | Rollback of viewed + collapsed · ✅ |
| D5 | P0 | VoiceOver · `DiffLineCell` | Drawn text, no accessibility | Static-text element, "Added line 42: …" labels, "Comment on line N" custom action · ✅ |
| D6 | P2 | Hit targets | 18×16 nav buttons, 10 pt thread chevron | 22×20 and 20×20 · ✅ |
| D7 | P1 | Threads | "Reply and resolve" only in the conversation sheet | Inline "Reply and resolve" · ✅ |
| D8 | P0 | Large PRs · `Queries.swift:95` | "Viewed" rebuilt from the first 100 files only | Paginate `files` · ⏭ |
| D9 | P0 | Perf · `PRDetailModel.swift:433` | Any comment action re-measures/re-highlights the whole diff | Per-row signature invalidation · ⏭ |
| D10 | P1 | Word-level highlight, expand context, ignore whitespace | Missing | ⏭ |
| D11 | P1 | Pending review | In-memory only | Server-side pending review · ⏭ |

### E. Review and comments

| # | P | Source | Problem → impact | Fix · status |
|---|---|---|---|---|
| E1 | P0 | `PRSheets.swift` `SheetFrame` | Sheet errors hidden behind the sheet | Inline `SheetErrorRow` (announced, dismissable); parent alert suppressed while a sheet is open · ✅ |
| E2 | P1 | Toolbar Approve | Silently submitted pending comments | "Approve and submit N pending comments?" · ✅ (macOS, Linux, Windows) |
| E3 | P1 | Merge sheet | No readiness; enabled green Merge on blocked PRs | Readiness row; "Merge anyway" in red when GitHub reports a block; UNKNOWN stays neutral · ✅ |
| E4 | P1 | Merge + delete branch | Delete failure swallowed | "Merged, but the branch … couldn't be deleted: …" shown after the sheet closes · ✅ |
| E5 | P2 | Discard pending comments | One click, no undo | Confirmation · ✅ (macOS, Linux) |
| E6 | P1 | Job log sheet | Infinite spinner without `databaseId` | Explains that the check has no log · ✅ |

### F. Claude Code workspace

Authentication, session launch and process handling were not changed.

| # | P | Source | Problem → impact | Fix · status |
|---|---|---|---|---|
| F1 | P1 | `ClaudeWorkspace.close` | One click stops a working agent | `requestClose`: confirmation when the tab is Working or Needs you · ✅ |
| F2 | P0 | Agents rows/tabs · `ClaudeViews.swift` | Tap-only, unlabeled | Combined accessibility element, button trait, action, "title, project, state" label · 🟡 (keyboard focus traversal still needs `List(selection:)`) |
| F3 | P1 | `SessionStateGlyph` | Colour-only state | Tooltip and label · ✅ |
| F4 | P1 | Agents PR inspector | GitHub-only: false "No PR" on forge accounts | Provider-aware message · ⏭ |

### G. Settings, auth and integrations

| # | P | Source | Problem → impact | Fix · status |
|---|---|---|---|---|
| G1 | P2 | `SettingsView.swift` | 12 sections in one scroll | Tabs: General · Accounts · Integrations (Jira) · Advanced; remembers the last tab · ✅ |
| G2 | P2 | Settings | Raw "OAuth Device Flow" field among preferences | Moved to Advanced as "GitHub OAuth app (advanced)" · ✅ |
| G3 | P1 | `AppModel.revoked` → Login | Expired token landed on login with no explanation | `loginNotice` banner, cleared on sign-in · ✅ |
| G4 | P2 | `LoginView` | Double submit while busy | Buttons disabled while busy · ✅ |

## What already works well (preserved)

Unlock flow (PIN limits, Touch ID, reset). Account-switch confirmation that explains running agents. Merge status wording and the clickable checks badge. List states: loader → error with Retry → context-specific empty state with "Clear filter". Re-review banner. `pullyard://claude/new` safety prompt. Command palette (modal trait, announcements, keyboard). NSTableView diff with drawn cells, sticky headers, cached heights, highlight limits, auto split. n/p/[/]/v/w/s review keys that respect text focus.

## Remaining risks

- Settings window title now follows the selected tab ("General"), as is standard for macOS tabbed settings.
- In compact mode, resizing the list column stores the clamped width (max 320 pt).
- The test bundles run with `PULLYARD_TOKEN`. If that token were rejected (401), `AppModel.revoked()` would call `Keychain.delete()` for the default item. This is existing behaviour, but it would touch the shared keychain service. It didn't happen in this run.
