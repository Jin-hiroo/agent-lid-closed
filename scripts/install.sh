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
LEGACY_SUDOERS=/etc/sudoers.d/claude-lid-closed
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

# Validate/create the aliases before stopping either app. Existing hooks can keep
# reporting safely because the live directory and its lock are never moved.
/usr/bin/python3 scripts/migrate-state.py "$LEGACY_STATE" "$STATE"

echo "==> Checking narrow pmset access"
if { [ -f "$SUDOERS" ] || [ -f "$LEGACY_SUDOERS" ]; } && \
   sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 && \
   sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
    echo "Reusing the existing pmset sudoers rule"
else
    rule="$(mktemp)"
    trap 'rm -f "$rule"' EXIT
    cat >"$rule" <<RULE
# Installed by Agent Lid Closed; allows only the two sleep settings it needs.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
RULE
    /usr/sbin/visudo -cqf "$rule"
    sudo install -m 0440 -o root -g wheel "$rule" "$SUDOERS"
    rm -f "$rule"
    trap - EXIT
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
In Codex, open /hooks and review/trust the Agent Lid Closed command hooks.
Hooks disabled by Codex configuration or policy will not run.
Status: "$HOOK" status
DONE
