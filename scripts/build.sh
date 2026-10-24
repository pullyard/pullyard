#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PullYard.app"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    mkdir -p build
    lipo -create .build/arm64-apple-macosx/release/PullYard .build/x86_64-apple-macosx/release/PullYard -output build/PullYard-universal
    lipo -create .build/arm64-apple-macosx/release/pullyard-mcp .build/x86_64-apple-macosx/release/pullyard-mcp -output build/pullyard-mcp-universal
    BIN=build/PullYard-universal
    HELPER=build/pullyard-mcp-universal
else
    swift build -c release
    BIN=.build/release/PullYard
    HELPER=.build/release/pullyard-mcp
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/PullYard"
cp "$HELPER" "$APP/Contents/Helpers/pullyard-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
GITHUB_CLIENT_ID="${PULLYARD_GITHUB_CLIENT_ID:-$(cat .github-oauth-client-id 2>/dev/null)}"
if [ -n "$GITHUB_CLIENT_ID" ]; then
    plutil -replace PYGitHubOAuthClientID -string "$GITHUB_CLIENT_ID" "$APP/Contents/Info.plist"
fi

if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift scripts/make_icon.swift Resources/Brand/icon.svg "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/THIRD-PARTY-NOTICES.txt LICENSE "$APP/Contents/Resources/"

codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP/Contents/Helpers/pullyard-mcp"
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "Built: $APP (signed with: ${SIGN_ID:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x PullYard 2>/dev/null || true
    pkill -x Shipyard 2>/dev/null || true
    rm -rf "$DEST/PullYard.app" "$DEST/Shipyard.app"
    cp -R "$APP" "$DEST/"
    echo "Installed: $DEST/PullYard.app"
fi
