#!/usr/bin/env bash
# Build the ownscribe recorder app: app/build/ownscribe.app (ad-hoc signed).
#   bash app/build.sh [debug|release]   (default: release)
#   bash app/build.sh release --open    (build, then launch)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
OUT="$APP_DIR/build/ownscribe.app"

# The native build system: with only the Command Line Tools, SwiftPM's newer default
# ("Unknown error parsing property list") fails before compiling anything.
SWIFT_BUILD=(swift build -c "$CONFIG" --package-path "$APP_DIR" --build-system native)
"${SWIFT_BUILD[@]}" 2>&1 | grep -v "build-system native' has been deprecated" || true
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path 2>/dev/null)/OwnscribeApp"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/ownscribe"
cp "$APP_DIR/Resources/Info.plist" "$OUT/Contents/Info.plist"
[ -f "$APP_DIR/Resources/AppIcon.icns" ] && cp "$APP_DIR/Resources/AppIcon.icns" "$OUT/Contents/Resources/"

# Ad-hoc signature: macOS ties the Microphone and System Audio Recording grants to it, so a
# rebuild may ask for them again.
codesign --force --sign - --identifier com.ownscribe.app "$OUT"
echo "Built: $OUT"

if [ "${2:-}" = "--open" ]; then open "$OUT"; fi
