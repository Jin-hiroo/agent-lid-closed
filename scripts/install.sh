#!/bin/bash
# Builds Claude Lid Closed, installs it to ~/Applications, starts it at login, and registers
# its hooks in your Claude Code settings. Asks for your password once, for the sudoers rule.
# Safe to re-run (e.g. after pulling changes).
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=local.ClaudeLidClosed
APP="$HOME/Applications/ClaudeLidClosed.app"
HOOK="$APP/Contents/Helpers/claude-lid-hook"
SUDOERS=/etc/sudoers.d/claude-lid-closed
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
USER_NAME="$(id -un)"

echo "==> Building"
./scripts/build-app.sh

echo "==> Stopping any running copy (it re-enables sleep as it quits)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeLidClosed 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x ClaudeLidClosed >/dev/null || break; sleep 0.5; done

echo "==> Installing $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R build/ClaudeLidClosed.app "$APP"

echo "==> Allowing '$USER_NAME' to run 'pmset -a disablesleep 0|1' without a password"
rule="$(mktemp)"
cat >"$rule" <<EOF
# Installed by Claude Lid Closed (scripts/install.sh); removed by scripts/uninstall.sh.
# Lets the menu bar app keep the Mac awake with the lid closed while Claude Code works.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
/usr/sbin/visudo -cqf "$rule"
if ! sudo cmp -s "$rule" "$SUDOERS" 2>/dev/null; then
    sudo install -m 0440 -o root -g wheel "$rule" "$SUDOERS"
fi
rm -f "$rule"
sudo -k # forget the cached password, so the next check proves the rule works on its own
if ! sudo -n /usr/bin/pmset -a disablesleep 0; then
    echo "error: the sudoers rule in $SUDOERS doesn't work" >&2
    exit 1
fi

echo "==> Adding hooks to $SETTINGS"
/usr/bin/python3 scripts/hooks.py install "$SETTINGS" "$HOOK"

echo "==> Starting at login"
mkdir -p "$(dirname "$AGENT")"
cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/ClaudeLidClosed</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Restart after a crash, so a crash can't leave sleep disabled. Quitting from the menu stays quit. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"

cat <<EOF

Done. The moon/cup icon in the menu bar is Claude Lid Closed.
New Claude Code sessions pick up the hooks automatically; restart sessions that are already open.
Check what it sees any time with:
  "$HOOK" status
EOF
