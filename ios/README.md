# PullYard for iPhone

Native iOS companion for PullYard. It connects directly to GitHub.com; there is no PullYard backend.

## Open and run

1. Install XcodeGen if it is not already installed.
2. From this directory, run xcodegen generate.
3. Open PullYardMobile.xcodeproj in Xcode.
4. Select the PullYardMobile scheme, choose a simulator or iPhone, set a signing team under Signing & Capabilities, and run.

The deployment target is iOS 17. Xcode 26 automatically presents native tab and navigation chrome with the current Liquid Glass treatment on supported OS versions.

## Build for a device from the command line

```bash
xcodegen generate
xcodebuild -project PullYardMobile.xcodeproj -scheme PullYardMobile -configuration Debug -destination 'id=<device-udid>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team-id> CODE_SIGN_STYLE=Automatic build
```

The app, the widget extension and the App Group `group.com.pullyard.mobile` are provisioned automatically for the given team. Set `PY_GITHUB_CLIENT_ID` (build setting) to ship a GitHub OAuth app for browser sign-in; without it, sign-in uses a token or a client ID entered on the sign-in screen.

## Connect GitHub

Create a classic personal access token with repo and notifications scopes. GitHub's notifications endpoints do not accept fine-grained personal access tokens. The app validates the token against /user, then stores it in this iPhone's Keychain. The same guide is available on the sign-in screen. Do not paste the token into issues or source files.

The app uses GitHub REST API v3 over HTTPS:

- GET /user
- Search API for review-requested and authored pull requests
- Pull request details, check runs, reviews, issue comments and inline review comments
- Create conversation comments, inline replies, and APPROVE / REQUEST_CHANGES / COMMENT reviews
- Unread notifications and mark-as-read

## Pull request projects

The app opens on **Pull requests**. Choose **Needs review** or **My PRs**, then filter by **All**, **Open**, or **Closed**. Tap **Choose** beside Project to search repositories and focus one project's pull requests, or choose **All projects**. Use **Reorder** to drag repositories into your preferred order; the selection and order are saved on this iPhone. The queue discovers additional repositories in the background through GitHub's Search API (up to its 1,000-result window), so you do not need to scroll through one repository's pull requests to reach another. **Inbox** is the second tab.

Repository data is cached in the iOS Caches directory to show the last successful queue while offline. The cache uses iOS file protection, is excluded from device backup, and is cleared on sign-out. The refresh interval runs only while the app is open; iOS may suspend it in the background. GitHub push notifications are not part of this backend-free version.

## Product boundaries

- This is a triage and response client, not a complete diff-review workspace. “Open on GitHub” hands off to a browser for file diffs.
- Only GitHub.com is included in this first iOS version. GitHub Enterprise and other forges need a separate tested host/auth flow.
- Device Flow sign-in needs a registered GitHub OAuth client ID. Until PullYard's owner registers one, token entry keeps this build usable without inventing credentials or shipping a client configuration.

## Project layout

- PullYardMobile/ — SwiftUI screens, app state, Keychain storage and GitHub REST client.
- project.yml — XcodeGen source of the standalone project.
- PLAN.md — full product and implementation plan.

GitHub API references: [pull request reviews](https://docs.github.com/en/rest/pulls/reviews), [notifications](https://docs.github.com/en/rest/activity/notifications), [fine-grained token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).
