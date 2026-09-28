#!/usr/bin/env bash
# Builds a release binary and wraps it into StatBar.app (LSUIElement, no
# Dock icon) so it behaves like a normal menu bar app instead of a dev build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

APP_DIR="$ROOT_DIR/dist/StatBar.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Ask SwiftPM where the universal binary went: the folder has moved
# between toolchains (.build/apple before Swift 6.4, .build/out after).
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_DIR/StatBar" "$CONTENTS/MacOS/StatBar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

if [ -f "$ROOT_DIR/Resources/AppIcon.png" ]; then
    echo "Building app icon…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ROOT_DIR/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ROOT_DIR/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run it directly with: open \"$APP_DIR\""
echo "It registers itself as a login item on first launch."
