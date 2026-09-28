#!/usr/bin/env bash
# Builds StatBar.app and wraps it in a DMG for a GitHub release, then prints
# the sha256 the Homebrew cask needs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/build_app.sh"

DMG="$ROOT_DIR/dist/StatBar.dmg"
rm -f "$DMG"

# The DMG holds the app next to an Applications shortcut, so installing is a
# single drag.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$ROOT_DIR/dist/StatBar.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "Creating DMG…"
hdiutil create \
    -volname "StatBar" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "Built: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
