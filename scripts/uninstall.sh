#!/bin/bash
# Removes everything install.sh set up and makes sure normal sleep is back.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=local.ClaudeLidClosed
APP="$HOME/Applications/ClaudeLidClosed.app"
SUDOERS=/etc/sudoers.d/claude-lid-closed
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

echo "==> Stopping the app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeLidClosed 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x ClaudeLidClosed >/dev/null || break; sleep 0.5; done
rm -f "$AGENT"

echo "==> Removing hooks from $SETTINGS"
[ -f "$SETTINGS" ] && /usr/bin/python3 scripts/hooks.py uninstall "$SETTINGS"

echo "==> Re-enabling sleep and removing the sudoers rule"
sudo /usr/bin/pmset -a disablesleep 0
sudo rm -f "$SUDOERS"

echo "==> Removing the app and its state"
rm -rf "$APP" "$HOME/Library/Application Support/ClaudeLidClosed"

echo "Done. The log is left at ~/Library/Logs/ClaudeLidClosed.log."
