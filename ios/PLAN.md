# PullYard for iPhone — implementation plan

## Product goal

A useful companion to PullYard desktop: know what needs attention, inspect a pull request and its CI, and take the small review actions that do not require a full code workspace. The iPhone app talks directly to GitHub; PullYard has no hosted backend. Credentials live only in the iOS Keychain.

## Decisions

- First release targets GitHub.com. GitHub Enterprise can follow after the public host flow is stable. GitLab/Bitbucket/Gitea are intentionally outside v1.
- Sign-in starts with a GitHub token pasted once. The app validates it with `GET /user`, stores it in Keychain and offers a clear least-privilege scope guide. This avoids shipping an OAuth client ID before the project owner registers an app. Device Flow can replace this onboarding once a public OAuth client ID is configured.
- Four primary destinations: Inbox, Pull requests, Search, Settings. The pull request queue opens with a clear project selector; project choice and custom order persist between launches. Root navigation stays native; Liquid Glass is reserved for system navigation and a small number of floating actions.
- Main task is triage/action. This is not a mobile diff editor; changed files open on GitHub when a full code review is needed.
- No server, telemetry, AI chat, or credential sync. Refresh works on demand and while foregrounded; iOS background execution is best-effort and no push service is implied.

## Build sequence

1. **Foundation** — standalone iOS Xcode project, app theme, Keychain credential vault, GitHub REST client, validation/error handling, persistent last-known data.
2. **Sign-in and account** — welcome, token entry with secure field, validate, account identity, sign out, privacy/scope guidance.
3. **Triage** — review-requested and authored PR queues, open/closed filters, refresh, useful empty/loading/error/offline states, sort/search, repository context, counts.
4. **PR workspace** — summary, participants/review state, merge status, status checks, review history, issue conversation, inline review comments, compose comment/reply.
5. **Actions** — approve, request changes with required explanation, general review comment, mark notification read/unsubscribe, open PR or file in GitHub.
6. **Inbox/search/settings** — GitHub notifications with unread state, global PR search, refresh interval and display options, token scope check, safe sign-out.
7. **Polish and delivery** — dynamic type, VoiceOver labels, haptics, iOS 26 materials, app icon, README, archive/install guidance. Build the iOS target and resolve all compiler issues; device launch depends on Xcode device/signing availability.

## Definition of done for v1

- A user can sign in with a GitHub token, see their own review queue and PRs, refresh them, open a PR, read its discussion and CI, add a comment/reply, submit one of the three review decisions, and manage notifications.
- Errors from revoked tokens, missing repository access, rate limits, network loss and missing scopes are surfaced in plain language with a recovery path.
- Stored credentials are protected by Keychain; repository cache is protected by iOS file protection, excluded from device backup, and cleared on sign-out.
- Core flows compile for device and simulator; the project includes an honest setup guide and does not pretend push notifications or mobile diff review exist.

## Current status

- [x] Product scope and implementation plan
- [x] iOS project, API and secure credential layer
- [x] Sign-in and triage
- [x] PR detail and review actions
- [x] Notifications, search, settings and polish
- [x] Project picker with search, reorder, saved selection and background queue indexing (up to GitHub Search API's 1,000-result window)
- [x] Open/closed/all pull request filter and Pull requests as the first, launch tab
- [x] Phase 1 of COUNCIL_PLAN.md: cache-first cold start, Keychain lock/401 handling, value-based navigation, queue upsert refresh, open/merged/closed/all lists, error banners and toasts, composer drafts with retry, pending review submit/discard, paginated conversation, commit statuses in checks, ETag conditional requests, unit tests, opaque app icon, privacy manifest
- [x] Builds for simulator and device; 15 unit tests pass; installs on a paired iPhone with a personal team (pass DEVELOPMENT_TEAM on the xcodebuild command line)
- [x] Phase 2 of COUNCIL_PLAN.md (most items): PullYard palette and radii, drawn logo loader and pull-to-refresh, GraphQL queues with CI / review decision / labels, five queue chips, new PR rows with context menu, PR detail with pinned sections, bottom action bar and next-in-queue, native Markdown blocks, review threads with diff hunks, grouped checks with progress bar, Inbox filters / Today-Earlier / Done with undo / Mute / Mark all read, new sign-in screen, search with recents and debounce
- [ ] Phase 2 leftovers: @Observable store refactor, unresolved-thread filter and jump-to-latest pill, PR state on Inbox rows, snooze, scope interstitial, search scopes/tokens
- [x] Phase 3 item 0 (owner priority): Projects tab (pinned, waiting for review, all account repositories with open PR counts, open any owner/name), project screen with Everyone / Needs my review / Mine and Open / Merged / Closed / All, Pull requests grouped by project with collapsible sections
- [x] Theme: richer PullYard palette with brand backdrop and serif titles, Settings choice PullYard / System plus Automatic / Light / Dark
- [x] Liquid Glass pass (iOS 26+): glass tab bar with search tab and minimize on scroll, chips, toasts, banners, pull-to-refresh capsule, PR action bar, merge/approve buttons, sign-in card; iOS 17-25 keep solid fills
- [x] Phase 3 items 1-6, 12, 13: Files changed list + native diff with inline threads and Viewed tracking, merge readiness card, Merge sheet (method, commit text, delete branch), Ready for review / Convert to draft / auto-merge / Update branch / Close / Reopen, reviewers card with re-request, labels / assignees / milestone / closing issues, resolve and unresolve threads, re-run failed checks, deep links (github.com links, pullyard:// scheme, owner/repo#n in Search), offline cache of the last 30 opened PRs
- [x] Phase 3 rest: background refresh (BGAppRefreshTask) with local notifications for new review requests, mentions, approvals / changes requested and failed checks on my PRs, app icon badge; GitHub browser sign-in (Device Flow) using PY_GITHUB_CLIENT_ID build setting or a user-entered OAuth client ID; PR timeline events (commits grouped, force-push, labels, ready, merged...), "new since your last visit" divider and dot on rows; reactions on comments; issue screen; Settings for notifications, PR defaults and links
- [x] Fix: crash opening a PR (async let in the PR loader) replaced with explicit tasks; all plain buttons now react to taps on their whole area
- [x] Phase 4: composer Markdown keyboard bar (bold, italic, code, quote, lists, link, @), Write/Preview, @-mention suggestions from participants; line comments in the diff (long-press a line) as single comments or into a pending review with "Finish review" and pending comment count; Viewed state synced with GitHub; onboarding (3 pages, skippable, before sign-in); saved searches as chips in Pull requests; dark and tinted app icon variants; haptics on Done; home-screen and Lock Screen widget (review count, top PRs with CI) through App Group `group.com.pullyard.mobile`; single refresh indicator (toolbar no longer shows a second loader)
- [ ] Phase 4 left: Settings behind the avatar (owner decision), full light/dark/AX5 visual pass on device
- [x] Offline outbox for comments, replies and reviews; Siri / Shortcuts (waiting for review, open queue, open PR link); interactive widget refresh; share extension "Open in PullYard"; Live Activity and Dynamic Island for CI on a PR; Handoff of the open PR; Russian localization (string catalog) with per-app language in iOS Settings; token shared with extensions through the App Group keychain group
