#!/bin/bash
# No power or user settings changes. Compile pure checks against the same core as the app.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${AGENT_LID_TEST_BIN:-$(./scripts/build-binaries.sh debug)}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
SDK="${AGENT_LID_SDK:-$(xcode-select -p)/SDKs/MacOSX.sdk}"
swiftc -swift-version 6 -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -I "$BIN" -L "$BIN" -lLidCore Tests/QuotaChecks/main.swift -o "$TEMP_DIR/quota-checks"
"$TEMP_DIR/quota-checks"
swiftc -swift-version 6 -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -I "$BIN" -L "$BIN" -lLidCore Tests/T3Checks/main.swift -o "$TEMP_DIR/t3-checks"
python3 scripts/test-t3.py "$TEMP_DIR/t3-checks" "${1:-build/AgentLidClosed.app}"
python3 scripts/test-quota.py "${1:-build/AgentLidClosed.app}"
python3 scripts/test-mixed.py "${1:-build/AgentLidClosed.app}"
