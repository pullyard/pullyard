#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
PROC="$1"; shift
cmd="$1"; shift
se() { osascript -e "tell application \"System Events\" to tell process \"$PROC\" to $1"; }
case "$cmd" in
  front) se "set frontmost to true" ;;
  size) se "set frontmost to true"; se "set position of window 1 to {${3:-80}, ${4:-60}}"; se "set size of window 1 to {$1, $2}" ;;
  link) se "set frontmost to true"; se "keystroke \"l\" using command down"; sleep 0.6; se "keystroke \"$1\""; sleep 0.3; se "key code 36" ;;
  keys) se "set frontmost to true"; se "keystroke \"$1\" using {${2:-command down}}" ;;
  key) se "set frontmost to true"; se "key code $1" ;;
  type) se "set frontmost to true"; se "keystroke \"$1\"" ;;
  shot)
    ID=$(build/ux-overhaul/winlist "${OWNER:-$PROC}" ${2:+"$2"} | head -1 | cut -d' ' -f1)
    screencapture -o -x -l "$ID" "$1"; echo "$1" ;;
  dark) osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to '"$1" ;;
esac
