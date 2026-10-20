# Agent Lid Closed

**Close your MacBook's lid while Claude Code or Codex works. Your Mac stays awake with the screen at 0% brightness, then sleeps when every agent is waiting for you.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Requires macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Builds with Swift 6.2 or later](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)](Package.swift)
[![Claude Code and Codex](https://img.shields.io/badge/agents-Claude%20Code%20%2B%20Codex-417E68)](#usage)

[Install](#install) · [Usage](#usage) · [How it works](#how-it-works) · [Settings](#settings) · [Limits](#limits)

<p>
  <a href="docs/images/menu-lid-closed-working.png"><img src="docs/images/menu-lid-closed-working.png" alt="Earlier Claude Lid Closed release: the cup menu reports lid closed, system sleep disabled, and two Claude Code sessions working." width="398"></a>
</p>

_Real screenshot from the earlier Claude-only release. The current menu also labels each session as Claude or Codex and includes a display dimming switch._

## Overview

Closing a MacBook's lid normally puts it to sleep even while `caffeinate` is running. Agent Lid Closed follows Claude Code and Codex lifecycle hooks, keeping the Mac awake while either tool has work to do.

- **Both tools, together.** Claude and Codex sessions share one sleep decision. The Mac stays awake while any tracked session is working, including tracked subagents.
- **Screen at 0% with the lid closed.** The app turns the built-in backlight off while keeping a closed Mac awake, then restores the previous brightness when you open the lid.
- **Sleep when turns finish.** Finished turns and input questions allow sleep once every session is waiting and its grace period has passed. Claude approval prompts also allow sleep; Codex approval requests keep the hold until the tool finishes or you interrupt.
- **Claude notifications still go out.** Claude sessions wait for Claude Code's delayed input notification. Codex sessions use the normal 10 s grace period without that extra wait.
- **See who is working.** Each menu row and terminal status line identifies the tool, project and activity.
- **Battery and heat limits.** At 15% battery or less on battery power, or serious thermal pressure, the app releases its sleep hold. Quitting restores sleep and brightness; launchd restarts the app after a crash to recover its saved state.
- **Small hooks, narrow access.** The helper writes local state and produces no stdout. Root access is limited to exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1`.

## Install

Requirements: a MacBook with macOS 14 or later, [Claude Code](https://code.claude.com/docs/en/overview) and/or a current [Codex CLI](https://learn.chatgpt.com/docs/cli) with lifecycle hooks, and the Command Line Tools with Swift 6.2 or later (`xcode-select --install`; full Xcode isn't needed). Tested on macOS 26 on Apple silicon, with Codex CLI 0.163.0 hook configuration.

```sh
git clone https://github.com/Jin-hiroo/agent-lid-closed.git && cd agent-lid-closed && ./scripts/install.sh
```

The installer:

1. Builds `AgentLidClosed.app` and installs it in `~/Applications`.
2. Adds `/etc/sudoers.d/agent-lid-closed`, asking for your password if needed. Upgrades reuse the existing Claude Lid Closed rule when available.
3. Adds Claude hooks to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) and Codex hooks to `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`). Existing files are backed up to `.bak`; other settings and hooks are preserved.
4. Starts the app now and at login via `~/Library/LaunchAgents/local.AgentLidClosed.plist`.

You can use either agent on its own. Both hook configurations are installed, so switching tools later needs no reinstall.

### Upgrading from Claude Lid Closed

Run the installer from this checkout after updating. It stops the old app, preserves preferences and session state, and replaces the old login agent. The old state path and `ClaudeLidClosed.app/Contents/Helpers/claude-lid-hook` remain compatible aliases so Claude sessions already open can keep reporting events. Your checkout directory does not need renaming.

The state directory may be a symlink to the existing Claude Lid Closed directory. This preserves the lock and files used by hooks that are already running.

Re-running the installer is supported. Remove the app and both integrations with `./scripts/uninstall.sh`.

## Usage

1. Restart Claude Code and Codex sessions after installing so they load the hooks.
2. **In Codex, open `/hooks` and review/trust the Agent Lid Closed command hooks.** Codex skips new or changed hooks until trusted. Hooks must also be enabled in Codex configuration and allowed by policy. See the [official hook setup guide](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).
3. Give either tool a task. The menu bar icon becomes a cup while work is active.
4. Close the lid. The Mac stays awake and the built-in display goes to 0% brightness.
5. When every tracked session is waiting, the Mac can sleep: normally after 10 s for Codex and Claude permission prompts, or 70–90 s after Claude finishes or asks a question, allowing its delayed notification to go out.

Open the lid to restore brightness. With an external display attached, macOS manages the built-in panel in clamshell mode; this app leaves brightness alone and does not force immediate system sleep.

Choose **Open Log** from the menu to view `~/Library/Logs/AgentLidClosed.log`.

To see the current sessions from a terminal:

```console
$ ~/Applications/AgentLidClosed.app/Contents/Helpers/agent-lid-hook status
Claude · DICOMergeForMac  working  (2 min)  b6b2cf46-59eb-4882-b8d5-fcc485fbbe24
Codex · agent-lid-closed  working  (3 min)  codex:thread-id
=> keep the Mac awake
```

## How it works

The app uses the system-wide `SleepDisabled` setting (`pmset disablesleep`) to prevent lid-closed sleep. Hooks report activity; they do not change power settings themselves.

```text
Claude Code ── hooks ──▶ agent-lid-hook                  ──┐
Codex       ── hooks ──▶ agent-lid-hook --provider codex ──┤
                                                         ▼
                    sessions/<session key>.json ◀── menu bar app watches
                                                         ├─ sleep disabled while any agent works
                                                         └─ built-in brightness 0% with lid closed
```

Session files are in `~/Library/Application Support/AgentLidClosed/sessions/`. Codex IDs are namespaced separately from Claude IDs. Records written by the old Claude-only version still load.

- **Activity.** `UserPromptSubmit` and tool hooks mark work active. `SubagentStart`/`SubagentStop` track child activity without overwriting the main session. Claude's `Stop` payload can also report background tasks.
- **Waiting.** Codex `Stop`, `request_user_input` tool calls and `Interrupt` hooks mark a session as waiting. Its `PermissionRequest` keeps work active because an approval hook may allow a command without showing a prompt. Claude uses its question tools, notifications and stop events.
- **Grace periods.** Codex waits `sleepGraceSeconds` after entering a waiting state. Claude waits for its input notification, up to `notifyTimeoutSeconds`, or uses the shorter grace after the notification arrives.
- **Claude interruptions.** Claude does not emit an Esc hook. After 20 s without activity, its transcript is checked for `[Request interrupted by user]`. Codex uses its `Interrupt` hook; its transcript format is not parsed.
- **Display.** Brightness is saved before setting it to 0. Once dimmed, it stays there during lid-closed sleep and is restored when the lid opens, checked twice a second. The saved value survives app restarts.

### Safety

- **Battery.** At or below the configured floor on battery power, normal sleep is restored.
- **Heat.** macOS thermal state “serious” or “critical” releases the sleep hold.
- **Exit and crash recovery.** Normal termination restores sleep and brightness. After a crash, launchd restarts the app so it can recover the hold marker and `dimmed-brightness` file.
- **Visible restoration.** Brightness is restored to at least 10%, even if macOS reported 0 before dimming.
- **Dead or stale sessions.** Sessions whose owning process exits are dropped. For app-server hosts, that process can outlive an individual conversation; cleanup then relies on `SessionEnd` or stale timeouts. Work without a hook event for 30 minutes is ignored; Claude background-only work expires after 60 minutes. PID start times distinguish reused process IDs.

## Menu

| Icon | Meaning |
| --- | --- |
| Cup | At least one agent is working; sleep is disabled |
| Hourglass | All sessions are waiting; the grace period is running |
| Moon | Normal sleep |
| Pause | Automatic Mode is off |
| Warning triangle | Setup needed, low battery or thermal limit; normal sleep |

The menu lists each session's tool, project and activity, plus lid state, system sleep state and whether the display is off. **Automatic Mode** controls sleep management. **Turn Display Off When Lid Closed** controls dimming and is on by default. **Open Log** and **Quit** are also available.

## Settings

Use `defaults write local.AgentLidClosed <key> <number>`. Timing and safety settings take effect within 5 s. Existing preferences from `local.ClaudeLidClosed` are copied once on upgrade unless the new domain already has a value.

| Key | Default | Meaning |
| --- | --- | --- |
| `notifyTimeoutSeconds` | 90 | Claude only: longest wait for the delayed input notification; 0 skips that wait |
| `sleepGraceSeconds` | 10 | Delay after a waiting notification, or after Codex starts waiting |
| `batteryFloorPercent` | 15 | At or below this percentage on battery power, allow sleep |
| `workingStaleMinutes` | 30 | Ignore working sessions and subagent markers after this long without events |
| `backgroundStaleMinutes` | 60 | Ignore Claude background-only work after this long without events |

Use the menu to toggle Automatic Mode and display dimming.

## Limits

- **Codex hook trust.** Installing the file does not trust the hooks. Review them through `/hooks` before relying on this app. Older Codex versions without these lifecycle events are unsupported.
- **Approval prompts.** Codex has no approval-accepted hook, and another hook can auto-allow a command. The app therefore keeps Codex awake through approval requests until tool completion, turn completion or interruption (subject to stale timeouts). For Claude, approving and immediately closing the lid can still allow sleep until that tool completes; bypassing permission prompts avoids that gap.
- **Codex background work.** Detached commands that outlive a completed turn are not included in Codex's `Stop` payload. They are not independently tracked. Claude background tasks and lifecycle-reported subagents are tracked.
- **Scheduled wakeups.** Timers and scheduled future turns do not keep the Mac awake between turns.
- **Hooks that continue a turn.** Another `Stop` or `SubagentStop` hook can request more work after this app has recorded completion. Until the next activity hook, the session may count as waiting. Increase the grace period or turn off Automatic Mode for long continuation-only workflows.
- **Manual sleep.** macOS may ignore manual sleep while the hold is active. Turn off Automatic Mode or quit first.
- **Private brightness API.** Apple silicon brightness control uses `DisplayServices`. If a future macOS removes that API, dimming is skipped and a failure is logged.
- **Other hosts and remote work.** Only hosts that load and run the configured local hooks are visible. Cloud sessions and hosts that skip hooks are not tracked; a running process alone does not imply an active turn.

## Development

```sh
swift build                    # debug build, when SwiftPM is available
./scripts/test-hook.sh         # Claude + Codex hook/state regression checks
python3 scripts/test-install.py # hook merging and upgrade compatibility checks
./scripts/build-app.sh         # build/AgentLidClosed.app

# Quit the installed app before running this check:
python3 scripts/test-display.py # both tools: dim, sleep, restore; no real power changes

# Run manually in dry-run mode:
AGENT_LID_DRY_RUN=1 AGENT_LID_FAKE_LID=closed AGENT_LID_STATE_DIR=/tmp/agent-lid \
  build/AgentLidClosed.app/Contents/MacOS/AgentLidClosed \
  -notifyTimeoutSeconds 6 -sleepGraceSeconds 2
```

The scripts fall back to direct `swiftc` builds if SwiftPM cannot start. With a mismatched local SDK, set `AGENT_LID_SDK` to a compatible SDK path for that fallback. For example, this machine's Swift 6.3 compiler works with `AGENT_LID_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

In a dry run, power and brightness changes are logged. Create `/tmp/agent-lid/lid-open` to simulate opening the lid. The old `CLAUDE_LID_STATE_DIR`, `CLAUDE_LID_DRY_RUN` and `CLAUDE_LID_FAKE_LID` variables remain accepted.

## License

[MIT](LICENSE). Agent Lid Closed was previously named Claude Lid Closed. It is an independent project, not affiliated with or endorsed by Anthropic or OpenAI. Claude and Claude Code are trademarks of Anthropic; Codex is an OpenAI product.
