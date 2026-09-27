#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Zoom Scheduler.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ZoomScheduler" "$APP/Contents/MacOS/ZoomScheduler"
/usr/libexec/PlistBuddy -c 'Print' resources/Info.plist >/dev/null
cp resources/Info.plist "$APP/Contents/Info.plist"
# Set SIGN_IDENTITY to a stable Apple Development/Developer ID identity for persistent TCC grants.
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built: $APP"
echo "Launch: open \"$APP\""
