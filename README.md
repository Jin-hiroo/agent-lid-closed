# Claude Lid Closed

**Close your MacBook's lid while Claude Code works. It stays awake until Claude finishes or needs you, then goes to sleep.**

[![License: MIT](https://img.shields.io/github/license/Jin-hiroo/claude-lid-closed)](LICENSE)
[![Requires macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Builds with Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![Driven by Claude Code hooks](https://img.shields.io/badge/Claude%20Code-hooks-D97757?logo=claude&logoColor=white)](https://code.claude.com/docs/en/hooks)

[Install](#install) · [Usage](#usage) · [How it works](#how-it-works) · [Settings](#settings) · [Limits](#limits)

<p>
  <a href="docs/images/menu-lid-closed-working.png"><img src="docs/images/menu-lid-closed-working.png" alt="The Claude Lid Closed menu under its cup icon. It reads: Keeping your Mac awake: Claude is working. Lid closed, system sleep disabled. DICOMergeForMac: working, 2 min. claudeLidClosed: working, 3 min. Then Automatic Mode (checked), Open Log, and Quit (restores normal sleep)." width="398"></a>
</p>

_The menu on a MacBook with its lid closed. Two Claude Code sessions are working, so the app has turned system sleep off. Once both are waiting for you, it turns sleep back on and the Mac goes to sleep._

## Overview

Closing a MacBook's lid puts it to sleep even while `caffeinate` is running, unless a display and power are connected. A long Claude Code task stops the moment you close the lid and walk away. Claude Lid Closed follows your sessions through Claude Code hooks and keeps the Mac awake only while Claude is actually working.

- **Close the lid mid-task.** While any session is generating, running tools or subagents, or has background tasks running, the app turns on `pmset disablesleep`, the one setting that keeps a closed MacBook running.
- **Sleeps as soon as Claude needs you.** When a turn finishes, Claude asks a question or for permission, an API error stops it, or you press Esc, sleep is allowed again. If the lid is closed, the Mac goes to sleep.
- **Claude Code's notification still goes out.** After a turn ends, the app waits for Claude Code's own "waiting for your input" notification before sleeping, so it can still reach your phone.
- **Several sessions at once.** The Mac stays awake while any of them is working, and the menu lists what each one is doing.
- **Never stuck awake.** Sleep is allowed again on battery at 15% or less, or when macOS reports the Mac is too hot. Quitting, logging out or a crash restores normal sleep, and sessions that exited or went quiet are dropped.
- **Stays out of Claude's way.** The hook takes about 5 ms, prints nothing and always exits 0.
- **Narrow root access.** A sudoers rule allows exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1`, and nothing else.

## Install

Requirements: a MacBook with macOS 14 or later, [Claude Code](https://code.claude.com/docs/en/overview), and the Command Line Tools with Swift 6.2 or later (`xcode-select --install`; full Xcode isn't needed). Tested on macOS 26 on Apple silicon.

```sh
git clone https://github.com/Jin-hiroo/claude-lid-closed.git
cd claude-lid-closed && ./scripts/install.sh
```

`install.sh` asks for your password once. It:

1. Builds `ClaudeLidClosed.app` and installs it to `~/Applications`.
2. Adds `/etc/sudoers.d/claude-lid-closed`, which lets your user run exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password.
3. Adds hooks to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), after backing it up to `settings.json.bak`. Your other settings and hooks are left as they are.
4. Starts the app now and at every login, via `~/Library/LaunchAgents/local.ClaudeLidClosed.plist`.

It's safe to re-run, for example after `git pull`. To remove everything, run `./scripts/uninstall.sh`.

## Usage

There's nothing to configure.

1. Restart any Claude Code sessions that were open before you installed, so they load the hooks.
2. Give Claude a task. The menu bar icon turns into a cup.
3. Close the lid and walk away.
4. When Claude needs you, the Mac goes to sleep: about 10 s after a permission prompt, or 70 to 90 s after a turn ends or Claude asks a question, once Claude Code's notification has gone out.

To see what happened, choose **Open Log** in the menu:

```
2026-10-15T19:37:30+0900 Keeping Mac awake: Claude is working
2026-10-15T19:57:30+0900 Sleep allowed: Claude is waiting for you
2026-10-15T19:57:30+0900 Lid is closed: sleeping now
```

To see what it's tracking right now:

```console
$ ~/Applications/ClaudeLidClosed.app/Contents/Helpers/claude-lid-hook status
DICOMergeForMac  working  (2 min)  b6b2cf46-59eb-4882-b8d5-fcc485fbbe24
claudeLidClosed  working  (3 min)  d8046136-1249-4270-a5f4-46b4f400aba2
=> keep the Mac awake
```

## How it works

Closing the lid always puts a Mac to sleep, whatever apps like `caffeinate` ask for. The one switch that overrides this is the system-wide `SleepDisabled` setting (`pmset disablesleep`). Without a charger and an external display, it's the only way to keep a MacBook running with the lid shut.

```
Claude Code ──hook event──▶ claude-lid-hook ──writes──▶ sessions/<session id>.json
                                                                 │ watched
menu bar app ◀───────────────────────────────────────────────────┘
└─ sudo pmset -a disablesleep 1/0, then sleep now if the lid is closed
```

The session files are in `~/Library/Application Support/ClaudeLidClosed/sessions/`.

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

The menu bar icon shows what the app is doing:

| Icon | Meaning |
| --- | --- |
| Cup | Claude is working: sleep is off |
| Hourglass | Every session is waiting: sleep comes back when the grace period ends |
| Moon | Normal sleep |
| Pause | Automatic Mode is off |
| Warning triangle | Setup is needed, the battery is low or the Mac is too hot: normal sleep |

The menu shows:
- The current state, lid state and the actual `SleepDisabled` value.
- Each session with what it's doing.
- An **Automatic Mode** switch (off = never touch sleep).
- **Open Log**, which opens `~/Library/Logs/ClaudeLidClosed.log`.
- **Quit**.

`claude-lid-hook status` prints the same session list from a terminal (see [Usage](#usage)).

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
  build/ClaudeLidClosed.app/Contents/MacOS/ClaudeLidClosed \
  -notifyTimeoutSeconds 6 -sleepGraceSeconds 2
```

## License

[MIT](LICENSE)

Claude Lid Closed is an independent project, not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.
