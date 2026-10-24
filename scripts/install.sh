#!/bin/bash
# Install Agent Lid Closed, including an upgrade from Claude Lid Closed.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=local.AgentLidClosed
LEGACY_LABEL=local.ClaudeLidClosed
APP="$HOME/Applications/AgentLidClosed.app"
LEGACY_APP="$HOME/Applications/ClaudeLidClosed.app"
HOOK="$APP/Contents/Helpers/agent-lid-hook"
SUDOERS=/etc/sudoers.d/agent-lid-closed
WAKE_HELPER=/Library/PrivilegedHelperTools/local.AgentLidClosed.wake
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
STATE="$HOME/Library/Application Support/AgentLidClosed"
LEGACY_STATE="$HOME/Library/Application Support/ClaudeLidClosed"
USER_NAME="$(id -un)"

echo "==> Building"
./scripts/build-app.sh

# Validate configs before stopping the running app or touching system settings.
/usr/bin/python3 - "$CLAUDE_SETTINGS" "$CODEX_HOOKS" <<'PY'
import json, os, sys
sys.path.insert(0, 'scripts')
from hooks import validate
for path in sys.argv[1:]:
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        validate(settings)
PY

echo "==> Enabling T3 Code usage-reset continuation (if installed)"
if ! /usr/bin/python3 scripts/configure-t3.py; then
    echo "error: T3 setup failed; the running app was left in place. Fix T3 settings and retry." >&2
    exit 1
fi

# Validate/create the aliases before stopping either app. Existing hooks can keep
# reporting safely because the live directory and its lock are never moved.
/usr/bin/python3 scripts/migrate-state.py "$LEGACY_STATE" "$STATE"

echo "==> Installing the root-owned wake helper"
sudo install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 0755 build/AgentLidClosed.app/Contents/Helpers/agent-lid-wake "$WAKE_HELPER"

# Install the current rule on every upgrade. `sudo -l` only proves that a command
# is permitted; cached administrator credentials can hide a missing NOPASSWD tag.
echo "==> Installing narrow power permissions"
rule="$(mktemp)"
trap 'rm -f "$rule"' EXIT
cat >"$rule" <<RULE
# Installed by Agent Lid Closed. The root-owned helper accepts only set <epoch> or clear
# and can only manage this app's wake alarms, at most 7 days ahead.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, $WAKE_HELPER
RULE
/usr/sbin/visudo -cqf "$rule"
sudo install -m 0440 -o root -g wheel "$rule" "$SUDOERS"
rm -f "$rule"
trap - EXIT

# Execute a harmless app-owned cleanup with the credential cache invalidated.
# Verify before stopping the running app so a permission error leaves it running.
echo "==> Verifying password-free wake access"
sudo -k
if ! sudo -n "$WAKE_HELPER" clear; then
    echo "error: password-free wake access failed; the running app was left in place. Check the sudoers rule at $SUDOERS." >&2
    exit 1
fi

echo "==> Stopping running copies (restores sleep and brightness)"
for label in "$LABEL" "$LEGACY_LABEL"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
done
for name in AgentLidClosed ClaudeLidClosed; do
    pkill -x "$name" 2>/dev/null || true
    for _ in {1..20}; do pgrep -x "$name" >/dev/null || break; sleep 0.25; done
    if pgrep -x "$name" >/dev/null; then echo "error: $name did not stop" >&2; exit 1; fi
done
sudo -n /usr/bin/pmset -a disablesleep 0

echo "==> Installing $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R build/AgentLidClosed.app "$APP"
# Keep the old helper path callable, without leaving an old app that could run too.
rm -rf "$LEGACY_APP"
mkdir -p "$LEGACY_APP/Contents/Helpers"
ln -s "$HOOK" "$LEGACY_APP/Contents/Helpers/claude-lid-hook"
rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

echo "==> Registering Claude Code and Codex hooks"
/usr/bin/python3 scripts/hooks.py install "$CLAUDE_SETTINGS" "$HOOK" claude
/usr/bin/python3 scripts/hooks.py install "$CODEX_HOOKS" "$HOOK" codex

echo "==> Starting at login"
mkdir -p "$(dirname "$AGENT")"
/usr/bin/python3 - "$AGENT" "$APP/Contents/MacOS/AgentLidClosed" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
        'Label': 'local.AgentLidClosed',
        'ProgramArguments': [sys.argv[2]],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'ProcessType': 'Interactive',
    }, f)
PY
launchctl bootstrap "gui/$(id -u)" "$AGENT"

cat <<DONE

Done. Agent Lid Closed is running in the menu bar.
Restart Claude Code and Codex sessions to load the new hooks.
Claude Code's status line now records subscription reset times and preserves your previous display.
Keep Claude's "Continue automatically at usage limit" enabled and leave its terminal session open.
Claude and Codex share wake alarms, scheduled two minutes before a detected reset.
T3 recovery supports weekly resets up to seven days away; terminal waits are limited to 24 hours.
T3 Code: native activity and reset recovery are tracked without Codex hook trust or account tokens.
Leave T3 Code running; its native recovery continues the same Claude/Codex conversation at reset.
Outside T3, Codex quota detection needs its local event log; continuation depends on that host.
In Codex, open /hooks and review/trust the Agent Lid Closed command hooks.
Hooks disabled by Codex configuration or policy will not run.
Status: "$HOOK" status
DONE
