#!/bin/bash
# Remove Agent Lid Closed and any legacy Claude Lid Closed installation.
set -euo pipefail
cd "$(dirname "$0")/.."

for name in AgentLidClosed ClaudeLidClosed; do
    launchctl bootout "gui/$(id -u)/local.$name" 2>/dev/null || true
    pkill -x "$name" 2>/dev/null || true
    for _ in {1..20}; do pgrep -x "$name" >/dev/null || break; sleep 0.25; done
    if pgrep -x "$name" >/dev/null; then echo "error: $name did not stop" >&2; exit 1; fi
    rm -f "$HOME/Library/LaunchAgents/local.$name.plist"
done

for settings in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "${CODEX_HOME:-$HOME/.codex}/hooks.json"; do
    if [ -f "$settings" ]; then /usr/bin/python3 scripts/hooks.py uninstall "$settings"; fi
done

sudo /usr/bin/pmset -a disablesleep 0
WAKE_HELPER=/Library/PrivilegedHelperTools/local.AgentLidClosed.wake
if [ -x "$WAKE_HELPER" ]; then sudo "$WAKE_HELPER" clear; fi
sudo rm -f /etc/sudoers.d/agent-lid-closed /etc/sudoers.d/claude-lid-closed
sudo rm -f "$WAKE_HELPER" /var/run/local.AgentLidClosed.wake.lock
for name in AgentLidClosed ClaudeLidClosed; do
    rm -rf "$HOME/Applications/$name.app" "$HOME/Library/Application Support/$name"
done

echo "Done. Logs are left in ~/Library/Logs/AgentLidClosed.log (and the legacy ClaudeLidClosed.log)."
