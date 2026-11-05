#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."

NAME="${1:-PullYard UX Test}"
SUFFIX="${2:-uxtest}"
OUT="${3:-build/ux-overhaul}"
EXE="PullYard${SUFFIX}"
APP="$OUT/$NAME.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/PullYard "$APP/Contents/MacOS/$EXE"
cp .build/release/pullyard-mcp "$APP/Contents/Helpers/pullyard-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "dev.vaache.shipyard.$SUFFIX" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$EXE" "$APP/Contents/Info.plist"
plutil -remove CFBundleURLTypes "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/THIRD-PARTY-NOTICES.txt LICENSE "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Helpers/pullyard-mcp"
codesign --force --sign - "$APP"

DOMAIN="dev.vaache.shipyard.$SUFFIX"
defaults write "$DOMAIN" legacyKeychainChecked -bool true
defaults write "$DOMAIN" jira.hasToken -bool false
defaults write "$DOMAIN" update.lastCheck -float "$(date +%s)"
echo "Built: $APP"
