#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?Usage: scripts/sign_release.sh <version>}"
TAG="v${TAG#v}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ASSETS=$(gh release view "$TAG" --json assets -q '.assets[].name')
WANTED=$(printf '%s\n' "$ASSETS" | grep -E -- '-windows-[a-z0-9]+-setup\.exe$|-linux-[a-z0-9_]+\.tar\.gz$' || true)
if [ -z "$WANTED" ]; then
    echo "No Windows installers or Linux tarballs on $TAG yet. Wait for the Windows and Linux workflows to attach them, then run this again." >&2
    exit 1
fi

for name in $WANTED; do
    gh release download "$TAG" --pattern "$name" --dir "$WORK" --clobber
    swift scripts/update_signing.swift sign "$WORK/$name"
    gh release upload "$TAG" "$WORK/$name.sig" --clobber
done

MISSING=()
for platform in "windows-x64-setup.exe" "windows-arm64-setup.exe" "linux-x86_64.tar.gz" "linux-aarch64.tar.gz"; do
    printf '%s\n' "$ASSETS" | grep -q -- "-$platform\$" || MISSING+=("$platform")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "warning: not on the release yet: ${MISSING[*]}. Run this again once they are attached." >&2
fi
