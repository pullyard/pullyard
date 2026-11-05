#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/../../.."
NAME="$1"; SUFFIX="$2"; OUTDIR="$3"; MODE="$4"
PROC="PullYard$SUFFIX"; S=docs/ux-overhaul/tools/shoot.sh; export OWNER="$NAME"
se() { osascript -e "tell application \"System Events\" to tell process \"$PROC\" to $1" >/dev/null 2>&1; }
sheet() { build/ux-overhaul/winlist "$NAME" | awk '$3=="" && $2!~/x(30|33|64)$/ {print $1}' | head -1; }
pkill -x "$PROC" 2>/dev/null; sleep 1
defaults write "dev.vaache.shipyard.$SUFFIX" theme.appearance -string "$MODE"
docs/ux-overhaul/tools/launch_test_app.sh "$NAME" >/dev/null; sleep 7
$S "$PROC" size 1380 860; sleep 1
$S "$PROC" keys 1; sleep 2
$S "$PROC" link "https://github.com/pullyard/pullyard/pull/45"; sleep 6
for i in 1 2 3 4 5 6 7 8; do
  d=$(osascript -e "tell application \"System Events\" to tell process \"$PROC\" to get description of UI element $i of toolbar 1 of window 1" 2>/dev/null)
  [ "$d" = "Merge" ] && MI=$i
done
se "click UI element ${MI:-6} of toolbar 1 of window 1"; sleep 2
screencapture -o -x -l "$(sheet)" "$OUTDIR/merge-sheet-$MODE.png"; se "key code 53"; sleep 1.5
for i in 1 2 3 4 5 6; do
  r=$(osascript -e "tell application \"System Events\" to tell process \"$PROC\" to get role of UI element 1 of UI element $i of toolbar 1 of window 1" 2>/dev/null)
  [ "$r" = "AXPopUpButton" ] && RI=$i && break
done
se "click UI element 1 of UI element ${RI:-4} of toolbar 1 of window 1"; sleep 2
screencapture -o -x -l "$(sheet)" "$OUTDIR/review-sheet-$MODE.png"; se "key code 53"
echo done
