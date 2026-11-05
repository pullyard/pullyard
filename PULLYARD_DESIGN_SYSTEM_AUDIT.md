# PullYard Design System Audit

## 1. Existing system (macOS, `Sources/PullYard/Shared/Theme.swift`)

| Group | Tokens |
|---|---|
| Surfaces | `syWindow` F7F5F0/0C1220 · `sySidebar` EFECE5/0A0F1B · `syList` F3F1EC/0E1526 · `syPanel` FDFCFA/101828 · `syRaised` FFFFFF/152036 · `sySunken` F1EEE8/0A101C · `syBar` F5F3EE/111A2C |
| Lines | `syLine` 1A2333@8% / A0AEC4@10% · `syLineStrong` @15% / @18% |
| Text | `syText` 1A2333/E6EBF2 · `syMuted` 5F6B7E/8693A8 · `syDim` (was 939AA8/5F6B80) |
| Hues | accent 2A8BC8/5BB8EC, sky, violet, coral, green, red, amber, teal, indigo, slate |
| Diff | addBG, delBG, hunkBG, addText, delText, hunkText, gutter |
| Type | `syLargeTitle … syCaption2` (11 styles, scaled by `TextZoom`) + `Font.sy(size:)` |
| Components | `Surface`/`.surface()`, `.card()`, `IconTile`, `ChipView`, `Avatar`, `StateBadge`, `LabelChip`, `CIIcon`, `OutcomeIcon`, `DiffStat`, `ErrorStateView`, `LoadingView`, `ListEmptyNote`, `ListErrorNote`, `ComposerBox`, `TabStrip`, `RefreshStatus/Footer`, `ToastBanner`, `Motion` |
| Missing before this branch | spacing, radius, tint opacity, elevation, on-accent / solid fills, hover / selected |

The theme has two styles (PullYard brand, System). Every token also has a system fallback. Keep this design.

## 2. Inconsistencies found (counts in `Sources/PullYard` at the start of the audit)

| Pattern | Count | Worst files |
|---|---|---|
| `cornerRadius` literals | 89, using 12 distinct values (1.5…16) | ChatViews, StackTab, CommandPalette |
| `.padding` literals off the 2/4 grid (1, 1.5, 3, 5, 7, 9, 11) | 55 of 404 | RootView, ClaudeViews, FilesTab |
| `.opacity(0.xx)` on colours | 85, using 17 distinct values (tint fills alone: 0.05 to 0.25) | ChatViews, JiraViews |
| `.system(size:)` ignoring TextZoom | ~20 | ChatTasksPanel, StackTab, ClaudeStatus |
| `Color(red:)` / duplicated brand palette | 14 (LogoLoader ≡ ClaudeStatus `BrandMark`) | LogoLoader |
| Ad-hoc shadows | 7 call sites, 7 different radius/opacity pairs | RootView, ShortLink, CommandPalette |
| Hand-rolled pills duplicating `ChipView` | 11+ | BranchTag, PRTag, BranchChip, StatusPill, JiraStatusPill |
| Hand-rolled banners | 4 (CIFailureBanner, ClaudeFixBanner, ReReviewBanner, ErrorBanner) | FixWithClaudeSheet |
| Empty-state variants | 4 (ClaudeEmptyState ×2, Jira, ErrorStateView vs ListErrorNote) | |

## 3. Contrast (WCAG, computed from token hex)

| Pair | Before | After |
|---|---|---|
| `syDim` text on panel, light | 2.4–2.8:1 | **3.8:1** (`7C8494`) |
| `syDim` text on panel, dark | 3.0–3.5:1 | **3.9:1** (`6B778C`) |
| StateBadge white on green/violet/red/slate, dark | 2.3–2.9:1 | **≥4.5:1** (new `*Fill` tokens) |
| Coral / accent `.borderedProminent`, dark | 2.2–3.0:1 | ⏭ switch those buttons to `syAccentFill` (token added) |
| Coloured caption text on its own 12% tint, light | 3.2–3.8:1 | ⏭ add text variants (see roadmap) |

## 4. Tokens added in this branch (`Theme.swift`)

```swift
Space.xxs 2 · xs 4 · s 6 · m 8 · l 12 · xl 16 · xxl 24
Radius.xs 4 · s 6 · m 8 · card 10 · l 12 · xl 16          // .card() now defaults to Radius.card
Tint.subtle 0.06 · banner 0.08 · chip 0.12 · tile 0.14 · strong 0.22
Elevation.popover / .floating / .sheet  + View.elevation(_:)
Font.syIcon(_ size:, weight:)                             // SF Symbols that follow TextZoom
Color.syAccentFill 1D70A6 · syGreenFill 2B7F50 · syVioletFill 5E48C8 · syRedFill B23A2A · sySlateFill 5B6476
Color.syOnAccent · syHover · sySelected
syDim  light 7C8494 / dark 6B778C                          // contrast fix
VisualState.fill                                          // solid badge fill per state
```

The `*Fill` values match what Windows already defines as `SyAccentFillBrush #1D70A6`, so all three platforms can share them.

## 5. Components improved

| Component | Change |
|---|---|
| `TabStrip` | `ViewThatFits`: labels → icons + badges when narrow, no mid-word wrapping; `badgeLabel` for accessibility; selected trait |
| `SidebarRow` / `SidebarGroup` / `SidebarView` | `Button`-based; `compact` environment switch for the icon rail; `sySelected`/`syHover` tokens |
| `AccountSwitcherFooter` | `compact` variant; works without a loaded user |
| `ToastBanner` | Error variant, token radius/elevation, announcement |
| `SheetFrame` | Optional `model:`; inline `SheetErrorRow`; header trait |
| `StateBadge` | Solid fills from tokens, never truncates |
| `IconTile`, `ChipView`, `SidebarIcon` | Tint and spacing tokens, accessibility-hidden decoration |
| `MergeStatusBar` | `static func status(_:)` shared with `MergeSheet`; Ready-for-review action |
| `LoadMoreErrorRow` (new) | Shared pagination error row |

## 6. Shared components still proposed (not implemented)

1. `Pill(text, icon:, tone:, style: .tinted|.outlined|.solid, size:)` to replace BranchTag, PRTag, BranchChip, StatusPill, JiraStatusPill and the inline pills.
2. `InlineBanner(tone:, icon:, title:, detail:, actions:)` for the CI, Fix, Re-review and Error banners.
3. `FloatingCapsule` + a single bottom overlay stack for the toast, rate-limit and clipboard banners (their bottom paddings depend on each other today).
4. `EmptyStateView(icon|logo, title, message, primary:, secondary:)`; merge `ErrorStateView` into `ListErrorNote(centered:)`.
5. `DisclosureHeader` for Settings, Project, RepoGroup and File headers.
6. `CountBadge(n, tone:)`.
7. A single `BrandMark` palette (drop the duplicate in `ClaudeStatus.swift:214`).
8. Codemod: replace the remaining literal radii/paddings/opacities with the new tokens file by file. Do it as a separate mechanical change, not mixed with UX changes.

## 7. Cross-platform token alignment

| Item | macOS | Linux `theme.rs` | Windows `Brand.xaml` / `Palette.cs` |
|---|---|---|---|
| Core hues and surfaces | source of truth | identical hex | identical hex |
| `dim` | 7C8494 / 6B778C ✅ | 7C8494 / 6B778C ✅ | 7C8494 / 6B778C ✅ |
| Accent fill | `syAccentFill` 1D70A6 ✅ | `sy_on_accent` only | `SyAccentFillBrush` 1D70A6 |
| Radius | `Radius` scale ✅ | `.sy-card` 12, raised 10, sunken 8, row 7 | literals 3–12 in C# |
| Type | TextZoom text styles | em-relative | literal 13/12/11 px (macOS points) |
| Extras | — | orange, selection | hover/selected/control/input brushes |

Recommendation: generate all three palettes and the radius/spacing scale from one source. `linux/brand.env` is the natural seed, turned into a JSON consumed by Swift, Rust and the C# build.
