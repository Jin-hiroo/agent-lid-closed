#!/bin/bash
# Builds build/ClaudeLidClosed.app (release, ad-hoc signed). Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/ClaudeLidClosed.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/ClaudeLidClosed" "$APP/Contents/MacOS/"
cp "$BIN/claude-lid-hook" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/claude-lid-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
