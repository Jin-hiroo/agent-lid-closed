#!/bin/bash
# Builds build/AgentLidClosed.app (release, ad-hoc signed). Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(./scripts/build-binaries.sh release)"
APP=build/AgentLidClosed.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Settings > Integrations adds and removes hooks with the installer's script.
cp scripts/hooks.py "$APP/Contents/Resources/hooks.py"
cp "$BIN/AgentLidClosed" "$APP/Contents/MacOS/"
cp "$BIN/agent-lid-hook" "$APP/Contents/Helpers/"
cp "$BIN/agent-lid-wake" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/agent-lid-hook"
codesign --force --sign - "$APP/Contents/Helpers/agent-lid-wake"
codesign --force --sign - "$APP"
echo "Built $APP"
