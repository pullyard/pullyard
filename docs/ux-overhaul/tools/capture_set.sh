#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/../../.."
NAME="$1"; SUFFIX="$2"; OUTDIR="$3"; MODE="${4:-dark}"
PROC="PullYard$SUFFIX"; export OWNER="$NAME"; S=docs/ux-overhaul/tools/shoot.sh
mkdir -p "$OUTDIR"
pkill -x "$PROC" 2>/dev/null; sleep 1
defaults write "dev.vaache.shipyard.$SUFFIX" theme.appearance -string "$MODE"
docs/ux-overhaul/tools/launch_test_app.sh "$NAME" >/dev/null; sleep 7
$S "$PROC" size 1380 860; sleep 1
$S "$PROC" keys 1; sleep 3
$S "$PROC" shot "$OUTDIR/main-laptop-$MODE.png"
$S "$PROC" size 1024 680; sleep 1.5
$S "$PROC" shot "$OUTDIR/main-small-$MODE.png"
$S "$PROC" size 1800 1100; sleep 1.5
$S "$PROC" shot "$OUTDIR/main-large-$MODE.png"
$S "$PROC" size 1380 860; sleep 1
$S "$PROC" link "https://github.com/pullyard/pullyard/pull/45"; sleep 6
$S "$PROC" shot "$OUTDIR/pr-detail-$MODE.png"
$S "$PROC" keys 4 "control down"; sleep 6
$S "$PROC" shot "$OUTDIR/diff-$MODE.png"
$S "$PROC" size 1024 680; sleep 2
$S "$PROC" shot "$OUTDIR/diff-small-$MODE.png"
$S "$PROC" size 1380 860; sleep 1
$S "$PROC" keys 6; sleep 3
$S "$PROC" shot "$OUTDIR/agents-$MODE.png"
$S "$PROC" keys "," ; sleep 2
$S "$PROC" shot "$OUTDIR/settings-$MODE.png" "Settings" || $S "$PROC" shot "$OUTDIR/settings-$MODE.png" "General"
osascript -e "tell application \"System Events\" to tell process \"$PROC\" to key code 53"
