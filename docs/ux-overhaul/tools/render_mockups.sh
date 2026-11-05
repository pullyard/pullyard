#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="${TMPDIR:-/tmp}/pullyard-mockup-chrome"
render() {
  local url="$1" out="$2" w="$3" h="$4"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check --user-data-dir="$PROFILE" --force-device-scale-factor=1 --window-size="$w,$h" --screenshot="$out" "$url" >/dev/null 2>&1
  echo "$out"
}
for p in windows linux; do
  for s in main detail diff settings; do
    for t in light dark; do
      for size in 1440x900 1280x800; do
        render "file://$PWD/mockups/$p/index.html?screen=$s&theme=$t" "$PWD/mockups/$p/$s-$t-$size.png" "${size%x*}" "${size#*x}"
      done
      render "file://$PWD/mockups/$p/index.html?screen=$s&theme=$t&variant=current" "$PWD/mockups/$p/current-$s-$t-1280x800.png" 1280 800
    done
  done
done
