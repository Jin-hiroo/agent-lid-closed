# Claude Lid Closed

A menu bar app that keeps your Mac running with the lid closed while Claude Code is working, and lets it sleep as soon as Claude is waiting for you.

- **Claude is working** (generating, running tools or subagents, or a turn that ended with background tasks still running): sleep is disabled, so you can close the lid and walk away. ☕ icon.
- **Claude is waiting for you** (the turn finished, it asked a question or for permission, it hit an API error, or you pressed Esc): sleep is allowed again. If the lid is closed, the Mac goes to sleep. 🌙 icon (⌛ during the short grace period).
- With several sessions, the Mac stays awake while any of them is working.

## Install

```sh
git clone https://github.com/Jin-hiroo/claude-lid-closed.git
cd claude-lid-closed
./scripts/install.sh
```

This needs macOS 14 or later and only the Command Line Tools (no Xcode). It:

1. Builds `ClaudeLidClosed.app` and installs it to `~/Applications`.
2. Adds `/etc/sudoers.d/claude-lid-closed`, which lets your user run exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password. It asks for your password once to install it.
3. Adds hooks to `~/.claude/settings.json`, after backing it up to `settings.json.bak`.
4. Starts the app now and at every login, via `~/Library/LaunchAgents/local.ClaudeLidClosed.plist`.

Sessions that were already open when you installed may not have the hooks. Restart them.

To remove everything, run `./scripts/uninstall.sh`.

## How it works

Closing the lid always puts a Mac to sleep, whatever apps like `caffeinate` ask for. The one switch that overrides this is the system-wide `SleepDisabled` setting (`pmset disablesleep`). Without a charger and an external display, it's the only way to keep a MacBook running with the lid shut.

```
Claude Code ──hook event──▶ claude-lid-hook ──writes──▶ ~/Library/Application Support/ClaudeLidClosed/sessions/
                                                                  │ watched
                                         menu bar app ◀───────────┘
                                         └─ sudo pmset -a disablesleep 1/0, then sleep now if the lid is closed
```

- `claude-lid-hook` (inside the app bundle) runs on each hook event: `UserPromptSubmit`, `PreToolUse`/`PostToolUse`, `Notification`, `Stop`, `SubagentStart`/`SubagentStop` and so on. It records each session's state in a small JSON file. It takes about 5 ms, prints nothing and always exits 0, so it can't get in Claude's way.
- The app watches those files and decides:
  - **Any session working → disable sleep.** That includes a running subagent, and a turn that ended with `background_tasks` still running (from the `Stop` payload).
  - **All sessions waiting → enable sleep, and sleep now if the lid is closed.** It doesn't force sleep when an external display is attached (clamshell mode).
- **Grace period.** When a turn finishes, Claude Code sends its own "waiting for your input" notification about 60 s later, which can reach your phone. The app waits for that notification, up to 90 s, and sleeps 10 s after it. Permission prompts are notified immediately, so those sleep after 10 s.
- **Esc.** No hook fires when you interrupt Claude. A session that has been quiet for 20 s gets its transcript checked for `[Request interrupted by user]`.

### Safety

- **Battery.** On battery at 15% or less, sleep is allowed again, and the Mac sleeps if the lid is closed.
- **Heat.** At macOS thermal state "serious" or worse, the same happens. A fanless MacBook Air in a bag gets hot.
- **Quitting.** Quitting the app (menu, logout, `launchctl`, Ctrl-C) always re-enables sleep. If the app crashes, launchd restarts it, and the restarted app undoes the setting it left behind.
- **Ended sessions.** A session whose Claude Code process has exited is dropped. So is a "working" session with no hook event for 30 minutes, or a background-only one with none for 60 minutes.

## Menu

The menu shows:
- The current state, lid state and the actual `SleepDisabled` value.
- Each session with what it's doing.
- An **Automatic Mode** switch (off = never touch sleep).
- **Open Log**, which opens `~/Library/Logs/ClaudeLidClosed.log`.
- **Quit**.

From a terminal:

```sh
~/Applications/ClaudeLidClosed.app/Contents/Helpers/claude-lid-hook status
```

## Settings

Change these with `defaults write local.ClaudeLidClosed <key> <number>`. They take effect within 5 s.

| Key | Default | Meaning |
| --- | --- | --- |
| `notifyTimeoutSeconds` | 90 | Longest wait for Claude Code's "waiting for input" notification before sleeping. Set it to 0 to skip waiting for that notification (sleep then follows after `sleepGraceSeconds`). |
| `sleepGraceSeconds` | 10 | Delay after Claude starts waiting (and has notified) before sleeping |
| `batteryFloorPercent` | 15 | On battery at or below this, allow sleep |
| `workingStaleMinutes` | 30 | A "working" session with no events for this long is ignored |
| `backgroundStaleMinutes` | 60 | Background tasks alone keep the Mac awake this long after Claude's last event |

## Limits

- **Approving a permission prompt, then immediately closing the lid.** No hook fires when you approve, so until that tool finishes the session still counts as waiting, and the Mac can sleep during it. This doesn't happen in bypass-permissions mode.
- **Scheduled wakeups** (`/loop`, cron-style tasks) don't keep the Mac awake. When Claude ends a turn to wait for a timer, the Mac sleeps.
- **Manual sleep.** While the app holds sleep off, macOS may ignore manual sleep (Apple menu → Sleep). Turn off Automatic Mode or quit the app first.
- **Hosts other than the CLI.** Claude Code hosts that don't load `~/.claude/settings.json` (some SDK-based apps) won't send hooks. Those sessions are invisible to the app.

## Development

```sh
swift build                    # debug build
./scripts/test-hook.sh         # hook/state checks against a temp directory
./scripts/build-app.sh         # build/ClaudeLidClosed.app

# Run the app without touching pmset, pretending the lid is closed, with short timings:
CLAUDE_LID_DRY_RUN=1 CLAUDE_LID_FAKE_LID=closed CLAUDE_LID_STATE_DIR=/tmp/lid \
  build/ClaudeLidClosed.app/Contents/MacOS/ClaudeLidClosed -notifyTimeoutSeconds 6 -sleepGraceSeconds 2
```

## License

[MIT](LICENSE)

Claude Lid Closed is an independent project, not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.
