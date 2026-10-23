#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$here/brand.env"
set +a
out="${1:-$here/dist}"
command -v cargo-about >/dev/null || { echo "cargo-about is not installed: cargo install cargo-about --locked --features cli --version 0.9.2" >&2; exit 1; }
mkdir -p "$out"
cargo about generate --fail --manifest-path "$here/Cargo.toml" --config "$here/about.toml" --output-file "$out/THIRD-PARTY-NOTICES.txt" "$here/about.hbs"
install -Dm644 "$out/THIRD-PARTY-NOTICES.txt" "$out/share/licenses/${APP_ID}/THIRD-PARTY-NOTICES.txt"
install -Dm644 "$here/../LICENSE" "$out/share/licenses/${APP_ID}/LICENSE"
echo "wrote $out/THIRD-PARTY-NOTICES.txt ($(grep -c '^' "$out/THIRD-PARTY-NOTICES.txt") lines)"
