# PullYard Cross-Platform UX Report

## Supported platforms (from the repository)

| Platform | Implementation | Stack | Run during this audit? |
|---|---|---|---|
| macOS 14+ | `Sources/`, `Package.swift` | Swift 5.10, SwiftUI + AppKit, SwiftTerm | **Yes.** Built, unit-tested (158 tests), launched as separate test bundles, screenshotted at 3 sizes × 2 themes |
| Linux (GNOME baseline: GTK 4.14, libadwaita 1.5) | `linux/` | Rust, GTK 4, libadwaita, VTE, WebKitGTK | **No.** No Rust toolchain or GTK runtime on this Mac. Static review only; changes not compiled |
| Windows 10 1809+ / 11 | `windows/` | C# .NET 8, WinUI 3 (Windows App SDK 1.8) | **No.** No .NET/WinUI on this Mac. Static review only; `windows/tools/strings.py --check` and XML validation pass; C# not compiled |

There is no mobile or web client. The `docs/` folder holds the marketing site and demo, which are not part of the app.

## Shortcut comparison

| Action | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Command palette | ⌘K | Ctrl+K | Ctrl+K | ok |
| Open by link | ⌘L (disabled on forge accounts now) | Ctrl+L | Ctrl+L | Windows: dead while a WebView has focus |
| Refresh | ⌘R | Ctrl+R, F5 | Ctrl+R, F5 | ok |
| Back | ⌘[ | Alt+Left, Ctrl+[ | Alt+Left, **Ctrl+[ and mouse Back added** | Windows was missing Ctrl+[ |
| Sections | ⌘1–6 | Ctrl+1–6 | Ctrl+1–6 | macOS menu now uses provider names and disables unsupported sections |
| Toggle sidebar | **⌃⌘S (new)** | none | pane button | proposed Linux F9, Windows Ctrl+Shift+S |
| PR tabs | ⌃1–9 | none | Ctrl+Shift+1–N | ⌃1–9 collides with Mission Control desktops; proposal ⌥⌘1–9 |
| Diff review keys | n p [ ] v w s **c C** | n p [ ] v w s | n p [ ] v w s | c/C (comment threads) is macOS only so far |
| Focus composer | ⌘J | none | Ctrl+J | Linux missing |
| Shortcut sheet | menus | Ctrl+? window | none (hints hidden) | Windows needs one |
| Close window | ⌘W | — | Alt+F4 → tray | |

## Platform findings

### macOS (verified on the running app)
- ✅ Compact icon rail below 1180 pt. Tab strip falls back to icons instead of wrapping. State badge no longer truncates. ⌃⌘S toggles the sidebar.
- ✅ Go menu: provider-native labels ("My Merge Requests"; the inbox title on forge accounts), unsupported sections disabled, Projects hidden on forge accounts, ⌘L disabled on forge accounts.
- ✅ Settings uses the native tabbed Settings window (General / Accounts / Integrations / Advanced).
- ⏭ Sidebar width is fixed (220 pt, not user-resizable). ⌃1–9 conflicts with Mission Control.

### Windows (static, not run). Why it feels poor today
1. **P0 DPI sizing.** `AppWindow.Resize(1380,860)` and the minimum size were in physical pixels. At 150% the window opened at about 920×573 effective pixels and the nav dropped to its icon rail. **Changed:** size and minimum are scaled by `GetDpiForWindow/96`, and the window is centred in the work area and clamped to it (`MainWindow.xaml.cs`, `WindowInterop.Scale`). *Not compiled.*
2. **P0 Mica hidden.** The opaque brand window brush plus a separate 36 px `SyBarBrush` title row create a colour band and hide Mica. Proposed in the mockups: 48 px tall title bar that contains back, pane toggle and a Ctrl+K search box, over translucent surfaces. ⏭
3. **P1 Type ramp.** `Ui.Text` defaults to 13 px (127 call sites at 13, 112 at 12). WinUI Body is 14. The mockups use 14/12/20. ⏭ (changing the default without seeing the result risks truncation in fixed-width columns)
4. **P1** Section views are rebuilt on every switch (lost scroll and filters). Theme change rebuilds the whole shell. WebView2 swallows most app shortcuts. Settings is a cramped modal `ContentDialog`. No shortcut sheet. ⏭
5. **Ported in this branch:** "Approve and submit N pending comments?" wording (+ resw strings regenerated with the repo tool), Ctrl+[ / mouse Back, dim-text contrast token.
6. Not ported: confirmation before discarding pending comments. WinUI allows only one `ContentDialog` at a time, so this needs an inline confirm inside the review dialog. ⏭

### Linux (static, not run)
- P1 No tray or background indicator after closing (`hold()`). P1 `OverlaySplitView` has no breakpoint or toggle, so narrow windows keep a 200 px sidebar. P2 List width not persisted. P2 PR-tab and Ctrl+J shortcuts missing. ⏭
- **Ported in this branch:** "Approve and submit N pending comments?" (`ui/pr/mod.rs`), confirmation before discarding pending comments (`ui/pr/sheets.rs`, `adw::AlertDialog`), dim-text contrast token (`theme.rs`). *Not compiled.*
- Already good: system font with em-relative sizes, `adw::StyleManager` dark mode, a shortcuts window, window size persistence, no dependence on GNOME-only APIs beyond libadwaita.

## Feature parity (UX-relevant)

| Item | macOS | Linux | Windows |
|---|---|---|---|
| Menu bar / tray | MenuBarExtra | **none** | tray + taskbar badge |
| App menu | full menu bar | hamburger | **none** |
| Shortcut help | menus | Ctrl+? | **none** |
| Window state persistence | system | yes | **none** |
| Compact layout for small windows | **icon rail (new)** | none | NavigationView compact (DPI-broken) |
| Inline sheet errors, merge readiness, draft persistence, comment navigation | **new** | no | no |

## Mockups (Windows and Linux)

**All images below are mockups or reconstructions rendered from HTML/CSS. None is a screenshot of a running Linux or Windows build.** They use the app's design tokens (`Brand.xaml` / `theme.rs` hex values, the new `dim` and `*Fill` tokens) and the design decisions verified on macOS: icon rail fallback, tab badges with text, a single refresh control, merge readiness in the conflict banner, inline thread drafts, C/⇧C comment navigation, tabbed or paged settings.

Sources: `docs/ux-overhaul/mockups/shared/mockup.{js,css}`, `docs/ux-overhaul/mockups/{windows,linux}/index.html?screen=main|detail|diff|settings&theme=light|dark[&variant=current]`. Re-render: `docs/ux-overhaul/tools/render_mockups.sh` (headless Chrome). The fonts are approximated: Segoe UI Variable, Inter and Cantarell are not installed on the rendering Mac, so the system font stands in.

Windows conventions shown: 48 px title bar with min/max/close on the right, back + pane toggle + Ctrl+K search inside it, Mica-like translucent shell with raised content panes, 14 px body, accent pill selection indicator, Settings as a page of setting cards, Ctrl shortcuts throughout.
Linux conventions shown: libadwaita header bar with centred title and subtitle, close button on the right (layout follows the desktop's button setting), sidebar list rows, boxed-list preferences with switches, Inter/Cantarell-style font. Nothing in the design depends on a specific desktop environment.

### Windows 11

#### Main window — sidebar + PR list

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![windows main light 1440x900 mockup](docs/ux-overhaul/mockups/windows/main-light-1440x900.png) | ![windows main dark 1440x900 mockup](docs/ux-overhaul/mockups/windows/main-dark-1440x900.png) |
| Proposed 1280x800 | ![windows main light 1280x800 mockup](docs/ux-overhaul/mockups/windows/main-light-1280x800.png) | ![windows main dark 1280x800 mockup](docs/ux-overhaul/mockups/windows/main-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![windows main light current reconstruction](docs/ux-overhaul/mockups/windows/current-main-light-1280x800.png) | ![windows main dark current reconstruction](docs/ux-overhaul/mockups/windows/current-main-dark-1280x800.png) |

#### PR details

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![windows detail light 1440x900 mockup](docs/ux-overhaul/mockups/windows/detail-light-1440x900.png) | ![windows detail dark 1440x900 mockup](docs/ux-overhaul/mockups/windows/detail-dark-1440x900.png) |
| Proposed 1280x800 | ![windows detail light 1280x800 mockup](docs/ux-overhaul/mockups/windows/detail-light-1280x800.png) | ![windows detail dark 1280x800 mockup](docs/ux-overhaul/mockups/windows/detail-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![windows detail light current reconstruction](docs/ux-overhaul/mockups/windows/current-detail-light-1280x800.png) | ![windows detail dark current reconstruction](docs/ux-overhaul/mockups/windows/current-detail-dark-1280x800.png) |

#### Diff viewer

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![windows diff light 1440x900 mockup](docs/ux-overhaul/mockups/windows/diff-light-1440x900.png) | ![windows diff dark 1440x900 mockup](docs/ux-overhaul/mockups/windows/diff-dark-1440x900.png) |
| Proposed 1280x800 | ![windows diff light 1280x800 mockup](docs/ux-overhaul/mockups/windows/diff-light-1280x800.png) | ![windows diff dark 1280x800 mockup](docs/ux-overhaul/mockups/windows/diff-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![windows diff light current reconstruction](docs/ux-overhaul/mockups/windows/current-diff-light-1280x800.png) | ![windows diff dark current reconstruction](docs/ux-overhaul/mockups/windows/current-diff-dark-1280x800.png) |

#### Settings

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![windows settings light 1440x900 mockup](docs/ux-overhaul/mockups/windows/settings-light-1440x900.png) | ![windows settings dark 1440x900 mockup](docs/ux-overhaul/mockups/windows/settings-dark-1440x900.png) |
| Proposed 1280x800 | ![windows settings light 1280x800 mockup](docs/ux-overhaul/mockups/windows/settings-light-1280x800.png) | ![windows settings dark 1280x800 mockup](docs/ux-overhaul/mockups/windows/settings-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![windows settings light current reconstruction](docs/ux-overhaul/mockups/windows/current-settings-light-1280x800.png) | ![windows settings dark current reconstruction](docs/ux-overhaul/mockups/windows/current-settings-dark-1280x800.png) |

### Linux (GTK 4 / libadwaita)

#### Main window — sidebar + PR list

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![linux main light 1440x900 mockup](docs/ux-overhaul/mockups/linux/main-light-1440x900.png) | ![linux main dark 1440x900 mockup](docs/ux-overhaul/mockups/linux/main-dark-1440x900.png) |
| Proposed 1280x800 | ![linux main light 1280x800 mockup](docs/ux-overhaul/mockups/linux/main-light-1280x800.png) | ![linux main dark 1280x800 mockup](docs/ux-overhaul/mockups/linux/main-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![linux main light current reconstruction](docs/ux-overhaul/mockups/linux/current-main-light-1280x800.png) | ![linux main dark current reconstruction](docs/ux-overhaul/mockups/linux/current-main-dark-1280x800.png) |

#### PR details

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![linux detail light 1440x900 mockup](docs/ux-overhaul/mockups/linux/detail-light-1440x900.png) | ![linux detail dark 1440x900 mockup](docs/ux-overhaul/mockups/linux/detail-dark-1440x900.png) |
| Proposed 1280x800 | ![linux detail light 1280x800 mockup](docs/ux-overhaul/mockups/linux/detail-light-1280x800.png) | ![linux detail dark 1280x800 mockup](docs/ux-overhaul/mockups/linux/detail-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![linux detail light current reconstruction](docs/ux-overhaul/mockups/linux/current-detail-light-1280x800.png) | ![linux detail dark current reconstruction](docs/ux-overhaul/mockups/linux/current-detail-dark-1280x800.png) |

#### Diff viewer

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![linux diff light 1440x900 mockup](docs/ux-overhaul/mockups/linux/diff-light-1440x900.png) | ![linux diff dark 1440x900 mockup](docs/ux-overhaul/mockups/linux/diff-dark-1440x900.png) |
| Proposed 1280x800 | ![linux diff light 1280x800 mockup](docs/ux-overhaul/mockups/linux/diff-light-1280x800.png) | ![linux diff dark 1280x800 mockup](docs/ux-overhaul/mockups/linux/diff-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![linux diff light current reconstruction](docs/ux-overhaul/mockups/linux/current-diff-light-1280x800.png) | ![linux diff dark current reconstruction](docs/ux-overhaul/mockups/linux/current-diff-dark-1280x800.png) |

#### Settings

| | Light | Dark |
|---|---|---|
| Proposed 1440x900 | ![linux settings light 1440x900 mockup](docs/ux-overhaul/mockups/linux/settings-light-1440x900.png) | ![linux settings dark 1440x900 mockup](docs/ux-overhaul/mockups/linux/settings-dark-1440x900.png) |
| Proposed 1280x800 | ![linux settings light 1280x800 mockup](docs/ux-overhaul/mockups/linux/settings-light-1280x800.png) | ![linux settings dark 1280x800 mockup](docs/ux-overhaul/mockups/linux/settings-dark-1280x800.png) |
| Current (reconstruction) 1280x800 | ![linux settings light current reconstruction](docs/ux-overhaul/mockups/linux/current-settings-light-1280x800.png) | ![linux settings dark current reconstruction](docs/ux-overhaul/mockups/linux/current-settings-dark-1280x800.png) |

## Validation summary

| Check | macOS | Linux | Windows |
|---|---|---|---|
| Build | `swift build` ✅, release build ✅ | not run | not run |
| Tests | `swift test` 158/158 ✅ | not run | not run |
| Runtime visual check | ✅ screenshots before/after, 3 sizes, light/dark, merge/review sheets | ❌ | ❌ |
| Static | QA agent diff review (9 issues fixed) | manual review of edited closures/imports | `strings.py --check` ✅, `xmllint` on `Brand.xaml`/resw ✅ |
