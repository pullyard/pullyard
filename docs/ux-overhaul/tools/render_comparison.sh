#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/../comparison"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="${TMPDIR:-/tmp}/pullyard-compare-chrome"
shot() { "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check --user-data-dir="$PROFILE" --force-device-scale-factor=1 --window-size="$2" --screenshot="$PWD/$3" "file://$PWD/src/index.html?screen=$1" >/dev/null 2>&1; echo "$3"; }
for s in main-small main pr-detail diff diff-small; do shot "$s" 2400,1180 "$s.png"; done
shot agents 2400,1000 agents.png
for s in merge-sheet review-sheet; do shot "$s" 2400,1120 "$s.png"; done
shot settings 1700,1300 settings.png
shot overview 2000,5900 overview.png
