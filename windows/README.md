# Agent Lid Closed for Windows

**Close your laptop's lid while Claude Code, Codex or T3 Code works. The PC stays awake, then does what closing the lid normally does once every agent is waiting for you.**

The Windows version of [Agent Lid Closed](../README.md). It has the same features and rules as the macOS app; the differences are listed under [Windows differences](#windows-differences).

[Install with AI](#tldr-install-with-an-ai-agent) · [Install](#install) · [Update](#updating) · [Usage](#usage) · [Settings](#settings) · [How it works](#how-it-works) · [Windows differences](#windows-differences) · [Limits](#limits)

## Features

- **Stays awake while an agent works**, lid closed included. Claude Code, Codex and T3 Code sessions share one decision; tracked subagents and background tasks count as work.
- **Lets it sleep when every agent is waiting**, after the same grace periods as on macOS: 10 s after a waiting state, or up to 90 s for Claude Code's delayed "waiting for your input" notification.
- **With the lid closed, does what closing the lid does**: sleeps or hibernates per your power plan's lid action. If that action is *Do nothing*, for example on a PC you use remotely with its lid closed, it stays awake.
- **Wakes before usage resets.** When Claude or Codex stops at a subscription limit, a wake timer brings the PC back two minutes before the earliest reset.
- **Switches T3 Code accounts at a usage limit**, and turns on T3 Code's native **auto-resume** after a reset.
- **Keep awake by hand**: until you turn it off, for 30 min, 1, 2 or 4 h, or for a typed time (`90`, `1:30`, `2h`, `1h 30m`), up to 7 days.
- **Battery floor.** At 15% or less on battery, normal sleep comes back.
- **Notification-area icon, menu and Settings window** in Japanese, with each session's tool or account, project and activity.

## TL;DR: install with an AI agent

Paste this into Claude Code, Codex or T3 Code on the Windows PC:

```text
Install Agent Lid Closed for Windows from https://github.com/Jin-hiroo/agent-lid-closed.
Clone it to %USERPROFILE%\dev\agent-lid-closed, or run `git pull` there if it already exists.
Read windows/README.md and windows/install.ps1, check that `node --version` is 22.16 or later,
and tell me in a few lines what the installer will change on this PC.
Then run: powershell -ExecutionPolicy Bypass -File windows\install.ps1
Afterwards run: node "$env:LOCALAPPDATA\Programs\AgentLidClosed\agent-lid.mjs" status
and tell me whether Claude Code, Codex and T3 Code are set up.
```

The installer needs no administrator password, so the agent can run it. Restart open Claude Code sessions afterwards; in Codex, trust the new hooks under `/hooks`.

## Requirements

- Windows 10 or 11. No administrator rights are needed.
- [Node.js](https://nodejs.org) 22.16 or later on `PATH`. It uses the built-in `node:sqlite` and `WebSocket`; there are no npm packages.
- The .NET Framework 4 that ships with Windows. Its C# compiler builds the tray app.
- Any of Claude Code, Codex CLI or T3 Code; one is enough.

## Install

From the cloned repository, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

The installer:

1. Quits a running copy (which restores sleep), builds `AgentLidClosed.exe` and installs the app in `%LOCALAPPDATA%\Programs\AgentLidClosed`.
2. Adds hooks for the tools it finds. Claude Code: hooks and a status-line wrapper in `~\.claude\settings.json`; an existing status line keeps working and is restored on uninstall. Codex: hooks in `~\.codex\hooks.json` (or `%CODEX_HOME%`). Each file is backed up to `.bak` first and recorded in `%LOCALAPPDATA%\AgentLidClosed\hook-targets.json`.
3. Enables T3 Code's `autoResumeLimitedThreads`, unless you turned it off.
4. Sets **Allow wake timers** to Enable for AC and battery in the active power plan. The previous values are saved per plan, before any change, and the uninstaller puts them back.
5. Starts the app now and at login (a shortcut in your Startup folder).

| Option | Effect |
| --- | --- |
| `-ClaudeConfigDir DIR` | Also add hooks for a Claude account you run with `CLAUDE_CONFIG_DIR=DIR`. Repeat for more. |
| `-Codex` | Add Codex hooks even though Codex wasn't found. |
| `-NoClaude`, `-NoCodex` | Skip that tool. |
| `-NoWakeTimers` | Leave the power plan's wake-timer setting alone. |
| `-NoStartAtLogin` | Don't add the Startup shortcut. |

Afterwards, restart open Claude Code sessions, and in Codex trust the new hooks under `/hooks`. T3 Code conversations are read directly and need nothing.

### Updating

```powershell
git pull; powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

The installer replaces the running copy and refreshes every recorded hook. Your settings are kept.

### Uninstalling

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\uninstall.ps1             # keeps the log and settings
powershell -ExecutionPolicy Bypass -File .\windows\uninstall.ps1 -RemoveData # deletes them too
```

It quits the app, puts back the lid action and wake-timer settings, removes every hook it added, and deletes the app and its Startup shortcut. If anything can't be undone, it leaves the app files in place (the hooks still use them), says what failed and exits with an error; run it again once that's fixed. T3 Code's auto-resume setting is left as it is.

## Usage

The icon in the notification area shows the state:

| Icon | Meaning |
| --- | --- |
| ☕ Cup | An agent is working; sleep is held off |
| ⌛ Hourglass | All sessions are waiting; the grace period is running |
| ☀ Sun | Kept awake by hand until you turn it off |
| ⏱ Timer | Kept awake by hand for a set time |
| ☾ Moon | Normal sleep |
| ⏸ Pause | Automatic mode is off |
| ⚠ Warning | Low battery, or the power state isn't known yet; normal sleep |

Click it for:

- The status, lid and sleep state, the next usage reset and the latest account switch.
- Each session: tool or account, project and activity, for example `Claude · my-app: 作業中 · 3 分`.
- **スリープさせない**: keep awake by hand, until you turn it off or for a set time.
- Toggles: **自動モード**, **使用量のリセット前にスリープ解除**, **使用上限でアカウントを切り替える** (when T3 Code has two accounts of one tool) and **リセット後に自動で再開する (T3 Code)**.
- **設定…**, **ログを開く** and **終了（通常のスリープに戻す）**.

A balloon notification tells you when a conversation was moved to another account.

From a terminal:

```powershell
$app = "$env:LOCALAPPDATA\Programs\AgentLidClosed"
node "$app\agent-lid.mjs" status            # sessions and the sleep decision
node "$app\agent-lid.mjs" plan              # T3 account switches it would make now
node "$app\agent-lid.mjs" set switch off    # or on: switch T3 accounts at usage limits
node "$app\agent-lid.mjs" set auto-resume on   # or off: T3's native auto-resume
& "$app\AgentLidClosed.exe" settings        # open the Settings window
& "$app\AgentLidClosed.exe" quit            # quit, restoring normal sleep
```

```console
> node "$app\agent-lid.mjs" status
Claude · my-app  作業中  (3 分)  t3:41d4c384-...
Codex · api  あなたを待っています（完了）  (12 分)  codex:019a...
=> PC を起こしておく
```

The log is `%LOCALAPPDATA%\AgentLidClosed\AgentLidClosed.log`.

### Which apps are tracked

| App | Kept awake while working | Wake before usage resets | Switch accounts at a limit |
| --- | --- | --- | --- |
| Claude Code in a terminal | Yes, through its hooks | Yes, from its status line | No |
| Codex CLI | Yes, once you trust its hooks in `/hooks` | Yes, from its local event log | No |
| T3 Code, with Claude or Codex | Yes, read directly; no hooks needed | Yes, and T3 continues the conversation | Yes, with two accounts of one tool |

## Settings

Choose **設定…** from the menu. Changes take effect within 5 s.

| Tab | What you can change |
| --- | --- |
| 一般 (General) | Automatic mode, start at login, and the battery level that allows sleep |
| タイミング (Timing) | How long to wait after agents stop, how long to wait for Claude's notification, when silent or background-only sessions stop counting; restore defaults |
| 使用量の上限 (Usage limits) | Waking before usage resets, T3 Code account switching with the accounts it would use (greyed out with the reason when it can't apply), T3 auto-resume |
| 連携 (Integrations) | Which Claude Code and Codex settings files have hooks, with Add and Remove buttons; **別のアカウントの設定フォルダを追加…** for a Claude account you run with `CLAUDE_CONFIG_DIR`; T3 Code and power status |

Settings are stored in `%LOCALAPPDATA%\AgentLidClosed\settings.json`, with the same keys and defaults as the macOS app's preferences:

| Key | Default | Meaning |
| --- | --- | --- |
| `autoEnabled` | true | Automatic mode |
| `notifyTimeoutSeconds` | 90 | Claude only: longest wait for the delayed input notification; 0 skips it |
| `sleepGraceSeconds` | 10 | Delay after a waiting notification, or after Codex starts waiting |
| `batteryFloorPercent` | 15 | At or below this on battery, allow sleep |
| `workingStaleMinutes` | 30 | Ignore working sessions and subagent markers after this long without events |
| `backgroundStaleMinutes` | 60 | Ignore Claude background-only work after this long without events |
| `wakeForQuotaReset` | true | Wake before usage resets |
| `switchAccountAtLimit` | true | Switch T3 Code accounts at a usage limit |

## How it works

```text
Claude Code ── hooks ──▶ agent-lid-hook.mjs ──────────────────┐
Codex       ── hooks ──▶ agent-lid-hook.mjs --provider codex ─┤
                                                              ▼
                                %LOCALAPPDATA%\AgentLidClosed\sessions\*.json
                                                              │
T3 Code     ── read-only database, every 5 s ─────────────────┤
                                                              ▼
                         agent-lid.mjs (decides) ◀── JSON lines ──▶ AgentLidClosed.exe
                                                                    ├─ lid, battery, displays
                                                                    ├─ sleep hold, sleep, wake timer
                                                                    └─ icon, menu, Settings
```

The Node.js side (`agent-lid.mjs`, `agent-lid-hook.mjs`, `lib/`) is a port of the macOS app's logic: the same hook handling and session files, grace periods and stale limits, Claude interrupt detection, Codex event-log quota reader, T3 Code reader and account switching. `AgentLidClosed.exe` is a small C# program (`native/AgentLidClosed.cs`, built with the .NET Framework's `csc` by `build.ps1`) that owns everything that needs Windows APIs. It starts the Node.js watcher, restarts it if it exits, and releases the hold whenever it isn't running or stops answering.

- **Holding sleep off.** Like `pmset disablesleep 1` on macOS: the power plan's lid close action is set to *Do nothing* for AC and battery, and `SetThreadExecutionState(ES_SYSTEM_REQUIRED)` blocks idle sleep. The previous lid action is saved to `power-hold.json` before any change and deleted only once it's verifiably back. It's put back when the hold ends, on quit, on sign-out, and on the next start after a crash; a restore that fails is retried every 15 s. If another power plan becomes active, the hold moves to it.
- **Sleeping with the lid closed.** When the hold ends with the lid closed and no external display, the tray reads the restored lid action, asks the watcher to confirm that no agent started meanwhile, checks the lid, displays and power source again, and then sleeps or hibernates as that action says.
- **Lid and displays.** The lid state comes from Windows' lid-switch notification; external displays from the display configuration (anything not built in). Unknown display state counts as an external display, so it never forces sleep then.
- **Wake timers.** A waitable timer with wake enabled, owned by the tray app. Quitting clears it.
- **Hooks.** Hook commands are `node "C:/…/agent-lid-hook.mjs"`, which works in Git Bash, cmd and PowerShell. They write session files under a named-pipe lock that Windows releases if a hook dies. They look up the agent process (the nearest ancestor that isn't a shell) through `AgentLidClosed.exe proc` on session start, new prompts, or when it isn't known yet, so most tool hooks stay fast. The wrapped status line is stored as base64, so no shell quoting is involved.
- **T3 Code.** As on macOS: a short read-only SQLite transaction every 5 s, the same queries, and account switches sent through T3's own `t3` command and local server with a five-minute credential that is revoked afterwards.

## Windows differences

- **Sleep follows your lid action.** macOS always sleeps when the lid closes; Windows does what **Power Options › Choose what closing the lid does** says. Set it to **Sleep** for the macOS behaviour.
- **No display toggle.** Windows turns the built-in display off by itself when the lid closes, whatever the lid action.
- **No heat limit.** Windows has no equivalent of macOS's thermal state for normal apps. The battery floor works as on macOS.
- **Wake timers** need **Allow wake timers** enabled, which the installer does. Modern Standby laptops may honour them only partly; test on your PC, plugged in.
- **No root helper or sudoers rule.** Everything runs as you; the only system changes are power-plan settings.

## Limits

- **Crash recovery.** If both the tray app and its watcher die, the lid action stays at *Do nothing* until the app starts again (at login, or by hand), which puts it back.
- **Codex hooks** must be trusted under `/hooks`, as on macOS. Codex background work outside a turn isn't tracked.
- **Claude approval prompts** allow sleep after the grace period, as on macOS; approving and immediately closing the lid can let the PC sleep until the tool completes.
- **Cloud sessions** and hosts that don't run local hooks aren't tracked.
- **Not yet verified on real hardware:** suspending from the tray and waking from a timer. Hold, release, hooks, T3 tracking and account switching were checked live.

## Development

```powershell
node --test --test-concurrency=1 "windows/test/*.test.mjs"   # hooks, evaluator, quota, installer, T3, controller
powershell -ExecutionPolicy Bypass -File windows\build.ps1     # windows\AgentLidClosed.exe
node windows\agent-lid.mjs run --dry-run                       # decide without a tray; power changes are only logged
```

With `AGENT_LID_STATE_DIR` set, sessions, settings and the log go to that folder, and T3 Code is ignored unless `AGENT_LID_T3_DIR` names a userdata folder. `AGENT_LID_HOME` points the hook installer at another home folder. In a dry run, `AGENT_LID_FAKE_LID=closed` pretends the lid is closed until a file named `lid-open` appears in the state folder. `AgentLidClosed.exe render-settings <status.json> <folder>` draws the Settings window's tabs to PNG files.
