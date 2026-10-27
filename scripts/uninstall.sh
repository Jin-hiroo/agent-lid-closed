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

# Every file the installer or Settings added hooks to, the default locations, and this
# shell's CLAUDE_CONFIG_DIR and CODEX_HOME. A file that can't be fixed doesn't stop the rest.
MANIFEST="$HOME/Library/Application Support/AgentLidClosed/hook-targets.json"
TARGETS="$(/usr/bin/python3 scripts/hooks.py targets --manifest "$MANIFEST")"
HOOK_FAILED=""
while IFS= read -r settings; do
    [ -n "$settings" ] || continue
    if ! /usr/bin/python3 scripts/hooks.py uninstall "$settings"; then
        echo "warning: couldn't remove the hooks from $settings; delete the entries that mention agent-lid-hook by hand." >&2
        HOOK_FAILED=1
    fi
done <<<"$TARGETS"
# Clear a "Start at Login" off choice.
launchctl enable "gui/$(id -u)/local.AgentLidClosed" 2>/dev/null || true

sudo /usr/bin/pmset -a disablesleep 0
WAKE_HELPER=/Library/PrivilegedHelperTools/local.AgentLidClosed.wake
if [ -x "$WAKE_HELPER" ]; then sudo "$WAKE_HELPER" clear; fi
sudo rm -f /etc/sudoers.d/agent-lid-closed /etc/sudoers.d/claude-lid-closed
sudo rm -f "$WAKE_HELPER" /var/run/local.AgentLidClosed.wake.lock
for name in AgentLidClosed ClaudeLidClosed; do
    rm -rf "$HOME/Applications/$name.app" "$HOME/Library/Application Support/$name"
done

echo "Done. Logs are left in ~/Library/Logs/AgentLidClosed.log (and the legacy ClaudeLidClosed.log)."
[ -z "$HOOK_FAILED" ] || exit 1
