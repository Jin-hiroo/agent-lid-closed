#!/bin/bash
# Install Agent Lid Closed, including an upgrade from Claude Lid Closed.
set -euo pipefail

usage() {
    cat <<USAGE
Usage: ./scripts/install.sh [options]

Hooks are added for Claude Code and Codex if they are installed. T3 Code needs no hooks.
  --claude-config-dir DIR  Also add Claude Code hooks to this config folder, for an account
                           you run with CLAUDE_CONFIG_DIR=DIR. Repeat for more folders.
  --no-claude              Don't add Claude Code hooks.
  --no-codex               Don't add Codex hooks.
  --codex                  Add Codex hooks even though Codex wasn't found.
Hooks can also be added or removed later in the app's Settings > Integrations.
USAGE
}

PLAN_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-config-dir)
            [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 64; }
            # Relative to the folder the installer was run from, not the source folder.
            case "$2" in
                /*|"~"*) PLAN_ARGS+=(--claude-config-dir "$2") ;;
                *) PLAN_ARGS+=(--claude-config-dir "$PWD/$2") ;;
            esac
            shift 2 ;;
        --no-claude|--no-codex|--codex) PLAN_ARGS+=("$1"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option $1" >&2; usage >&2; exit 64 ;;
    esac
done
cd "$(dirname "$0")/.."

LABEL=local.AgentLidClosed
LEGACY_LABEL=local.ClaudeLidClosed
APP="$HOME/Applications/AgentLidClosed.app"
LEGACY_APP="$HOME/Applications/ClaudeLidClosed.app"
HOOK="$APP/Contents/Helpers/agent-lid-hook"
SUDOERS=/etc/sudoers.d/agent-lid-closed
WAKE_HELPER=/Library/PrivilegedHelperTools/local.AgentLidClosed.wake
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/AgentLidClosed"
LEGACY_STATE="$HOME/Library/Application Support/ClaudeLidClosed"
MANIFEST="$STATE/hook-targets.json"
USER_NAME="$(id -un)"

echo "==> Building"
./scripts/build-app.sh

# Which settings files get hooks: installed tools, files that already have them, named folders.
PLAN="$(/usr/bin/python3 scripts/hooks.py plan --manifest "$MANIFEST" ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"})"
plan_paths() {
    /usr/bin/python3 -c 'import json, sys; [print(p) for p in json.loads(sys.argv[1])[sys.argv[2]]]' "$PLAN" "$1"
}
CLAUDE_TARGETS="$(plan_paths claude)"
CODEX_TARGETS="$(plan_paths codex)"

# Validate configs before stopping the running app or touching system settings.
/usr/bin/python3 - "$PLAN" <<'PY'
import json, os, sys
sys.path.insert(0, 'scripts')
from hooks import validate
plan = json.loads(sys.argv[1])
for path in plan['claude'] + plan['codex']:
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        validate(settings)
PY

echo "==> Enabling T3 Code usage-reset continuation (if installed)"
if ! /usr/bin/python3 scripts/configure-t3.py --preserve-choice; then
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

echo "==> Registering hooks"
# One file that can't be written must not stop the app from starting.
HOOK_FAILED=""
while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "    Claude Code: $path"
    /usr/bin/python3 scripts/hooks.py install "$path" "$HOOK" claude --manifest "$MANIFEST" || HOOK_FAILED=1
done <<<"$CLAUDE_TARGETS"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "    Codex: $path"
    /usr/bin/python3 scripts/hooks.py install "$path" "$HOOK" codex --manifest "$MANIFEST" || HOOK_FAILED=1
done <<<"$CODEX_TARGETS"
if [ -z "$CLAUDE_TARGETS$CODEX_TARGETS" ]; then
    echo "    Neither Claude Code nor Codex was found. Add hooks later in Settings > Integrations."
fi

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
# "Start at Login" off in Settings disables the job; start it now and keep that choice,
# even if starting fails.
DISABLED="$(launchctl print-disabled "gui/$(id -u)" 2>/dev/null || true)"
if grep -qE "\"$LABEL\" => (disabled|true)" <<<"$DISABLED"; then
    launchctl enable "gui/$(id -u)/$LABEL"
    started=0
    launchctl bootstrap "gui/$(id -u)" "$AGENT" || started=$?
    launchctl disable "gui/$(id -u)/$LABEL"
    [ "$started" -eq 0 ] || exit "$started"
else
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
fi

echo
echo "Done. Agent Lid Closed is running in the menu bar; open its Settings to adjust it."
if [ -n "$CLAUDE_TARGETS" ]; then
    echo "Claude Code: restart open sessions to load the hooks. Keep \"Continue automatically at"
    echo "  usage limit\" on in /config so a session continues after a reset."
fi
if [ -n "$CODEX_TARGETS" ]; then
    echo "Codex: open /hooks and trust the Agent Lid Closed hooks; Codex skips untrusted hooks."
fi
if [ -f "$HOME/.t3/userdata/settings.json" ]; then
    echo "T3 Code: tracked directly, without hooks. Leave it running to continue after usage resets."
fi
echo "Status: \"$HOOK\" status"
if [ -n "$HOOK_FAILED" ]; then
    echo "warning: some hooks weren't added (see the errors above). Fix those files, then add the hooks in Settings > Integrations." >&2
    exit 1
fi
