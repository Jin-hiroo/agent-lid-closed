#!/bin/bash
# Builds build/AgentLidClosed.app (release, ad-hoc signed). Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(./scripts/build-binaries.sh release)"
APP=build/AgentLidClosed.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/AgentLidClosed" "$APP/Contents/MacOS/"
cp "$BIN/agent-lid-hook" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/agent-lid-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
