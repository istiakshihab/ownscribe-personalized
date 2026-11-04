#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(dirname "$SCRIPT_DIR")/bin"

mkdir -p "$BIN_DIR"

# Process taps (per-app and system audio) need macOS 14.2. Name it, or each compiler picks its own
# default: a new one builds for the Mac it runs on, an older Xcode for an earlier macOS, which rejects them.
MIN_MACOS="14.2"

echo "Building ownscribe-audio..."
swiftc \
    -O \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -o "$BIN_DIR/ownscribe-audio" \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework AVFAudio \
    -framework AVFoundation \
    -framework AppKit \
    -framework CoreGraphics \
    -framework CoreAudio \
    -framework AudioToolbox \
    "$SCRIPT_DIR"/Sources/*.swift

echo "Built: $BIN_DIR/ownscribe-audio"
