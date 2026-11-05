#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
NAME="${1:-PullYard UX Test}"
OUT="${2:-build/ux-overhaul}"
REPO="${PULLYARD_DEMO_REPO:-pullyard/pullyard}"
TOKEN="${PULLYARD_TOKEN:-$(gh auth token 2>/dev/null || true)}"
EXE=$(plutil -extract CFBundleExecutable raw "$OUT/$NAME.app/Contents/Info.plist")
PULLYARD_TOKEN="$TOKEN" PULLYARD_DEMO_REPO="$REPO" nohup "$OUT/$NAME.app/Contents/MacOS/$EXE" >/dev/null 2>&1 &
echo "Launched $NAME (pid $!)"
