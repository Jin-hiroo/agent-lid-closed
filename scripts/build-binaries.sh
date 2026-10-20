#!/bin/bash
# Print the binary directory on stdout; build diagnostics go to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
[[ "$CONFIG" == release || "$CONFIG" == debug ]] || exit 64

# Some CLT releases have an unusable SwiftPM but a working compiler. This package
# has no third-party dependencies, so the same targets can be compiled directly.
if /usr/bin/python3 -c 'import subprocess, sys; sys.exit(subprocess.run(["swift", "build", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0)'; then
    swift build -c "$CONFIG" >&2
    swift build -c "$CONFIG" --show-bin-path
else
    echo "SwiftPM unavailable; building with swiftc." >&2
    BIN="$PWD/build/swiftc-$CONFIG"
    mkdir -p "$BIN"
    SDK="${AGENT_LID_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
    # Prefer the CLT's selected SDK symlink over xcrun's highest-version SDK.
    # A newer SDK can be left behind by a partial developer tools update.
    CLT_SDK="$(xcode-select -p)/SDKs/MacOSX.sdk"
    if [[ -z "${AGENT_LID_SDK:-}" && -d "$CLT_SDK" ]]; then SDK="$CLT_SDK"; fi
    FLAGS=(-swift-version 6 -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0")
    if [[ "$CONFIG" == release ]]; then FLAGS+=(-O); else FLAGS+=(-Onone -g); fi
    swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module \
        -module-name LidCore Sources/LidCore/*.swift -o "$BIN/libLidCore.a" \
        -emit-module-path "$BIN/LidCore.swiftmodule" >&2
    swiftc "${FLAGS[@]}" -I "$BIN" -L "$BIN" -lLidCore \
        Sources/agent-lid-hook/main.swift -o "$BIN/agent-lid-hook" >&2
    swiftc "${FLAGS[@]}" -parse-as-library -I "$BIN" -L "$BIN" -lLidCore \
        Sources/AgentLidClosed/*.swift -o "$BIN/AgentLidClosed" >&2
    echo "$BIN"
fi
