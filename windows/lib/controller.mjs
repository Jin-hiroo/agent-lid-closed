// Port of Sources/AgentLidClosed/Controller.swift. Keeps the computer awake, lid closed included,
// while any Claude Code, Codex or T3 Code session is working, and lets it sleep again (right away,
// if the lid is closed) once they're all waiting for you. Windows power control itself happens in
// AgentLidClosed.exe; this side decides and sends it `hold`, `sleepNow` and `wake`.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { canSwitch, plan as planSwitches, sameSwitch } from './planner.mjs';
import * as T3 from './t3.mjs';
import { dispatch } from './commands.mjs';
import { Processes } from './process.mjs';
import { SessionStore, shortSessionID, sessionsDirectory } from './sessions.mjs';
import { describeDuration, evaluate, lidSettings, quotaWakePlan, MAXIMUM_MANUAL } from './evaluator.mjs';
import { InterruptCache } from './transcript.mjs';
import { refreshCodexQuota } from './codexQuota.mjs';
import * as Hooks from './hooks.mjs';
import { loadAppSettings, log, paths, setT3AutoResume, stateDirectory, writeJSONAtomic } from './settings.mjs';

const appDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export const hookScript = path.join(appDir, 'agent-lid-hook.mjs');

const RETRY_DELAY = 30;
const MAXIMUM_DELIVERY_FAILURES = 3;
const SWITCH_INTERVAL = 600;
const ACCEPTED_HOLD = 120;
const BOOLEAN_KEYS = ['autoEnabled', 'wakeForQuotaReset', 'switchAccountAtLimit'];
const NUMBER_KEYS = { batteryFloorPercent: [0, 100], sleepGraceSeconds: [0, 3600], notifyTimeoutSeconds: [0, 3600],
  workingStaleMinutes: [1, 10000], backgroundStaleMinutes: [1, 10000] };
const DEFAULTS = { autoEnabled: true, wakeForQuotaReset: true, switchAccountAtLimit: true,
  batteryFloorPercent: 15, sleepGraceSeconds: 10, notifyTimeoutSeconds: 90, workingStaleMinutes: 30, backgroundStaleMinutes: 60 };

const nowSeconds = () => Date.now() / 1000;

export function formatTime(seconds, withDate = false) {
  const date = new Date(seconds * 1000);
  const pad = (n) => String(n).padStart(2, '0');
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  return !withDate && date.toDateString() === new Date().toDateString() ? time : `${date.getMonth() + 1}/${date.getDate()} ${time}`;
}

function age(since) {
  const minutes = Math.floor((nowSeconds() - since) / 60);
  return minutes < 1 ? 'たった今' : minutes < 60 ? `${minutes} 分` : `${Math.floor(minutes / 60)} 時間 ${minutes % 60} 分`;
}

export function startupShortcut() {
  return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'),
    'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'Agent Lid Closed.lnk');
}

function setStartAtLogin(enabled) {
  const shortcut = startupShortcut();
  if (!enabled) {
    try { fs.unlinkSync(shortcut); } catch { /* already gone */ }
    return null;
  }
  const exe = path.join(appDir, 'AgentLidClosed.exe');
  const script = `$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:ALC_LINK);$s.TargetPath=$env:ALC_EXE;`
    + `$s.WorkingDirectory=$env:ALC_DIR;$s.Description='Agent Lid Closed';$s.Save()`;
  const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
    windowsHide: true, timeout: 15_000, env: { ...process.env, ALC_LINK: shortcut, ALC_EXE: exe, ALC_DIR: appDir },
  });
  return result.status === 0 ? null : 'ログイン時の起動を設定できませんでした';
}

/**
 * `power` connects to the tray: send(message) and the latest report. Without a tray (`--dry-run`),
 * power changes are only logged and the lid is simulated with files, like the macOS dry run.
 */
export class Controller {
  constructor({ send = () => {}, tray = false } = {}) {
    this.send = send;
    this.tray = tray;
    this.store = new SessionStore();
    this.interrupts = new InterruptCache();
    this.t3Cache = new T3.T3Cache();
    this.power = { lidClosed: false, onBattery: false, battery: null, externalDisplay: false, holding: false };
    this.powerReported = !tray;
    this.holding = false;
    this.transitioning = false;
    this.pendingHold = null;
    this.holdID = 0;
    this.retryAt = 0;
    this.lastError = null;
    this.pendingSleepAt = null;
    this.releaseTimer = null;
    this.evaluation = { sessions: [], keepAwake: false, sleepAllowedAt: 0 };
    this.blocker = null;
    this.loggedSummary = null;
    this.scheduledWakeAt = null;
    this.wakeSynchronized = false;
    this.wakeInFlight = false;
    this.wakeRetryAt = 0;
    this.wakeError = null;
    this.lastT3WakeAt = null;
    this.displayOffSent = false;
    this.switches = new Map();
    this.lastSwitchAt = new Map();
    this.switchStatus = null;
    this.events = [];
    this.eventID = 0;
    this.t3 = null;
    this.integrations = [];
    this.integrationsAt = 0;
  }

  // ---- settings

  get settings() {
    return { ...DEFAULTS, ...loadAppSettings() };
  }

  saveSetting(key, value) {
    const stored = loadAppSettings();
    if (value === undefined) delete stored[key];
    else stored[key] = value;
    writeJSONAtomic(paths.settings, stored);
  }

  get manualUntil() {
    const value = this.settings.manualAwakeUntil;
    if (value === -1) return Infinity;
    return Number.isFinite(value) && value > 0 ? value : null;
  }

  get manualActive() {
    const until = this.manualUntil;
    return until != null && until > nowSeconds();
  }

  notify(title, message) {
    this.eventID += 1;
    this.events.push({ id: this.eventID, title, message });
    this.events = this.events.slice(-10);
  }

  // ---- lifecycle

  start() {
    fs.mkdirSync(sessionsDirectory(), { recursive: true });
    log(`Started${this.tray ? '' : ' (dry run)'}`);
    // As the macOS installer does: enable T3's native continuation unless the user turned it off.
    try {
      const result = setT3AutoResume(path.join(T3.defaultT3Directory(), 'settings.json'), true, { preserveChoice: true });
      if (result === 'changed') log('T3 Code: native auto-resume after usage resets enabled');
      if (result === 'preserved') log('T3 Code: preserving your disabled auto-resume preference');
    } catch (error) {
      log(`Could not configure T3 auto-resume (${error.message})`);
    }
    const until = this.manualUntil;
    if (until != null) {
      if (until > nowSeconds()) {
        log(`Sleep still disabled by hand ${this.describeManual(until)}`);
        this.scheduleManualEnd();
      } else {
        this.saveSetting('manualAwakeUntil', undefined);
      }
    }
    this.ticker = setInterval(() => this.evaluate(), 5000);
    try {
      this.watcher = fs.watch(sessionsDirectory(), () => this.queueEvaluate());
      this.watcher.on('error', () => { this.watcher = null; });
    } catch { /* the 5 s tick still runs */ }
    this.evaluate();
  }

  queueEvaluate() {
    if (this.evaluateQueued) return;
    this.evaluateQueued = true;
    setTimeout(() => {
      this.evaluateQueued = false;
      this.evaluate();
    }, 150);
  }

  /** On quit: never leave the computer unable to sleep. The tray also releases on its side. */
  async shutdown() {
    clearInterval(this.ticker);
    if (this.manualUntil != null) this.saveSetting('manualAwakeUntil', undefined);
    if (this.tray) {
      this.send({ type: 'wake', at: null });
      if (this.holding || this.power.holding) {
        await this.requestHold(false);
        log('Quit: sleep allowed again');
      }
    }
  }

  // ---- messages from the tray

  handle(message) {
    switch (message?.type) {
      case 'power':
        this.power = {
          lidClosed: message.lidClosed === true, onBattery: message.onBattery === true,
          battery: Number.isFinite(message.battery) ? message.battery : null,
          // Unreadable displays count as attached: no explicit sleep then, as with clamshell use.
          externalDisplay: message.externalDisplay !== false, holding: message.holding === true,
        };
        if (!this.transitioning) this.holding = this.power.holding;
        this.powerReported = true;
        if (!this.power.lidClosed) this.displayOffSent = false;
        this.queueEvaluate();
        break;
      case 'holdResult':
        if (this.pendingHold && message.id === this.pendingHold.id) {
          const resolve = this.pendingHold.resolve;
          this.pendingHold = null;
          resolve(message);
        }
        break;
      case 'wakeResult': {
        // Only the reply to the latest request counts; an older one may describe a replaced alarm.
        if (message.id !== this.wakeRequestID) break;
        this.wakeInFlight = false;
        clearTimeout(this.wakeDeadline);
        const armedAt = Number.isFinite(message.armedAt) ? message.armedAt : null;
        if (message.ok) {
          if (message.error !== this.wakeError && message.error) log(message.error);
          // A warning (wake timers disabled in Power Options) leaves the alarm set: show it, don't resend.
          this.wakeError = message.error ?? null;
          this.wakeRetryAt = 0;
          this.scheduledWakeAt = this.requestedWakeAt;
          this.wakeSynchronized = true;
          log(this.requestedWakeAt != null ? `Wake scheduled for usage reset: ${new Date(this.requestedWakeAt * 1000).toISOString()}` : 'Usage wake cleared');
        } else {
          if (message.error !== this.wakeError) log(message.error);
          this.wakeError = message.error;
          this.wakeRetryAt = nowSeconds() + 30;
          this.wakeFailedTarget = this.requestedWakeAt;
          // What's actually armed now; the desired alarm is sent again after the retry delay.
          this.scheduledWakeAt = armedAt;
          this.wakeSynchronized = false;
        }
        break;
      }
      case 'resumed':
        this.evaluate();
        break;
      case 'released':
        // The tray finished a release that had failed before (its repair tick).
        if (!this.transitioning) {
          this.holding = false;
          this.sleepIfLidClosed();
        }
        break;
      case 'confirmSleep': {
        // The tray asks right before suspending: re-decide with the latest hooks and T3 state.
        this.evaluate();
        const settings = this.settings;
        const ok = !this.holding && !this.transitioning && this.blocker?.kind !== 'setupNeeded' && !this.manualActive
          && (this.blocker != null || !settings.autoEnabled
            || (!this.evaluation.keepAwake && this.quotaHoldUntil == null && nowSeconds() >= this.evaluation.sleepAllowedAt));
        this.send({ type: 'sleepConfirmed', id: message.id, ok });
        break;
      }
      case 'command':
        this.command(message);
        break;
      default:
        break;
    }
  }

  command(message) {
    switch (message.name) {
      case 'set': {
        const { key, value } = message;
        if (BOOLEAN_KEYS.includes(key) && typeof value === 'boolean') {
          this.saveSetting(key, value);
          log(`${key} ${value ? 'on' : 'off'}`);
          if (key === 'switchAccountAtLimit' && !value) this.switchStatus = null;
        } else if (key === 'startAtLogin' && typeof value === 'boolean') {
          const error = setStartAtLogin(value);
          if (error) this.send({ type: 'alert', message: error });
          else log(`Start at login ${value ? 'on' : 'off'}`);
        } else if (NUMBER_KEYS[key] && Number.isFinite(value)) {
          const [min, max] = NUMBER_KEYS[key];
          this.saveSetting(key, Math.min(max, Math.max(min, value)));
        }
        break;
      }
      case 'restoreTimingDefaults':
        for (const key of ['sleepGraceSeconds', 'notifyTimeoutSeconds', 'workingStaleMinutes', 'backgroundStaleMinutes']) {
          this.saveSetting(key, undefined);
        }
        break;
      case 'manual': {
        const seconds = message.seconds;
        if (seconds != null && !(Number.isFinite(seconds) && seconds >= 1 && seconds <= MAXIMUM_MANUAL)) break;
        const until = seconds == null ? -1 : nowSeconds() + seconds;
        this.saveSetting('manualAwakeUntil', until);
        log(`Sleep disabled by hand ${this.describeManual(until === -1 ? Infinity : until)}`);
        this.scheduleManualEnd();
        break;
      }
      case 'manualOff':
        if (this.manualUntil != null) {
          this.saveSetting('manualAwakeUntil', undefined);
          log('Manual sleep disable turned off: back to automatic');
        }
        break;
      case 'autoResume':
        try {
          setT3AutoResume(path.join(T3.defaultT3Directory(), 'settings.json'), message.value === true);
          log(`T3 auto-resume ${message.value === true ? 'on' : 'off'}`);
        } catch (error) {
          this.send({ type: 'alert', message: `T3 Code の設定を変更できませんでした (${error.message})` });
        }
        break;
      case 'hooks':
        try {
          const target = Hooks.apply(message.action === 'uninstall' ? 'uninstall' : 'install', message.path,
            { provider: message.tool === 'codex' ? 'codex' : 'claude', hookScript });
          log(`${message.action === 'uninstall' ? 'Removed hooks from' : 'Added hooks to'} ${target}`);
          this.notify('Agent Lid Closed', message.action === 'uninstall' ? 'フックを削除しました。' : 'フックを追加しました。開いているセッションを再起動してください。');
        } catch (error) {
          this.send({ type: 'alert', message: `フックを変更できませんでした: ${error.message}` });
        }
        this.integrationsAt = 0;
        break;
      case 'refresh':
        this.integrationsAt = 0;
        break;
      case 'quit':
        this.shutdown().finally(() => {
          this.send({ type: 'exit' });
          setTimeout(() => process.exit(0), 200);
        });
        return;
      default:
        return;
    }
    this.evaluate();
  }

  describeManual(until) {
    return until === Infinity ? 'until turned off'
      : `for ${describeDuration(until - nowSeconds())} (until ${formatTime(until)})`;
  }

  scheduleManualEnd() {
    clearTimeout(this.manualTimer);
    const until = this.manualUntil;
    if (until == null || until === Infinity) return;
    this.manualTimer = setTimeout(() => this.evaluate(), Math.max(0, until - nowSeconds()) * 1000 + 50);
  }

  // ---- power

  requestHold(hold) {
    if (!this.tray) {
      log(`[dry run] ${hold ? 'hold' : 'release'} sleep`);
      this.power.holding = hold;
      return Promise.resolve({ ok: true, holding: hold });
    }
    this.holdID += 1;
    const id = this.holdID;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (this.pendingHold?.id === id) this.pendingHold = null;
        resolve({ ok: false, error: '電源設定の変更に応答がありません', holding: this.power.holding });
      }, 20_000);
      this.pendingHold = { id, resolve: (reply) => { clearTimeout(timer); resolve(reply); } };
      this.send({ type: 'hold', id, hold });
    });
  }

  get lidClosed() {
    if (this.tray) return this.power.lidClosed;
    const env = process.env.AGENT_LID_FAKE_LID;
    return env === 'closed' && !fs.existsSync(path.join(stateDirectory(), 'lid-open'));
  }

  currentBlocker(settings) {
    if (!settings.autoEnabled && !this.manualActive) return { kind: 'paused' };
    if (this.tray && !this.powerReported) return { kind: 'setupNeeded' };
    const battery = this.power.battery;
    if (this.power.onBattery && battery != null && battery <= lidSettings(settings).batteryFloor) {
      return { kind: 'batteryLow', percent: battery };
    }
    return null;
  }

  static describeBlocker(blocker) {
    switch (blocker.kind) {
      case 'paused': return '自動モードはオフです';
      case 'setupNeeded': return '電源の状態を確認しています';
      default: return `バッテリー残量 ${blocker.percent}%: スリープを許可`;
    }
  }

  transition(hold, why) {
    this.transitioning = true;
    this.requestHold(hold).then((reply) => {
      this.transitioning = false;
      if (!reply.ok) {
        if (reply.error !== this.lastError) log(reply.error);
        this.lastError = reply.error;
        this.retryAt = nowSeconds() + 30;
        this.holding = reply.holding === true;
        this.evaluate();
        return;
      }
      this.lastError = null;
      this.retryAt = 0;
      this.holding = hold;
      if (hold) {
        log(`Keeping the computer awake: ${why}`);
        this.evaluate();
        return;
      }
      log(`Sleep allowed: ${why}`);
      this.sleepIfLidClosed();
    });
  }

  /** After the hold ends: with the lid closed, do what closing the lid does. */
  sleepIfLidClosed() {
    // Hooks or a quota warm-up can arrive while the power change runs. Refresh before an
    // explicit sleep so we don't put a newly active session back to sleep.
    this.evaluate();
    if (this.holding || this.transitioning) return;
    const settings = this.settings;
    const maySleep = this.blocker != null || (!this.manualActive && (!settings.autoEnabled
      || (!this.evaluation.keepAwake && this.quotaHoldUntil == null && nowSeconds() >= this.evaluation.sleepAllowedAt)));
    if (maySleep && this.lidClosed && !this.power.externalDisplay) {
      log('Lid is closed: doing what closing the lid does (sleep unless its action is "Do nothing")');
      if (this.tray) this.send({ type: 'sleepNow' });
      else log('[dry run] sleep now');
    }
  }

  synchronizeWake(desired) {
    if (!this.tray) {
      if (desired !== this.scheduledWakeAt) {
        log(`[dry run] wake ${desired == null ? 'clear' : new Date(desired * 1000).toISOString()}`);
        this.scheduledWakeAt = desired;
      }
      return;
    }
    // The retry delay holds back only the alarm that failed; a different one goes out at once.
    if (this.wakeInFlight || (nowSeconds() < this.wakeRetryAt && desired === this.wakeFailedTarget)) return;
    if (this.wakeSynchronized && desired === this.scheduledWakeAt) return;
    this.wakeInFlight = true;
    this.requestedWakeAt = desired;
    this.wakeRequestID = (this.wakeRequestID ?? 0) + 1;
    // A lost reply must not stop alarm updates for good.
    clearTimeout(this.wakeDeadline);
    this.wakeDeadline = setTimeout(() => {
      this.wakeInFlight = false;
      this.wakeSynchronized = false;
      this.wakeRetryAt = nowSeconds() + 30;
      this.wakeFailedTarget = desired;
    }, 20_000);
    this.send({ type: 'wake', id: this.wakeRequestID, at: desired });
  }

  /** Windows turns the built-in display off itself when the lid closes, whatever the lid action,
   *  so unlike macOS nothing needs to be dimmed. This only notes it for the menu. */
  updateDisplay() {
    const off = this.lidClosed && !this.power.externalDisplay;
    if (off && !this.displayOffSent) log('Lid closed: Windows turned the built-in display off');
    this.displayOffSent = off;
  }

  // ---- account switching (see AccountSwitch.swift)

  switchPlan(snapshot, settings, now) {
    if (!settings.switchAccountAtLimit) return { switches: [], earlierResets: {} };
    return planSwitches({ threads: snapshot.limitedThreads, accounts: snapshot.accounts, limitedUntil: snapshot.limitedUntil,
      now, continuationDisabled: snapshot.continuationDisabled });
  }

  updateAccountSwitches(t3, settings, now) {
    let earlierResets = {};
    if (!t3.error) {
      const limitedRuns = new Map(t3.limitedThreads.map((t) => [t.threadID, t.runID]));
      for (const [id, attempt] of this.switches) if (limitedRuns.get(id) !== attempt.runID) this.switches.delete(id);
      for (const [id, at] of this.lastSwitchAt) if (now - at >= SWITCH_INTERVAL) this.lastSwitchAt.delete(id);
      const current = this.switchPlan(t3, settings, now);
      earlierResets = current.earlierResets;
      const planned = new Map(current.switches.map((s) => [s.threadID, s]));
      for (const [id, attempt] of this.switches) {
        if (attempt.phase !== 'retrying') continue;
        const candidate = planned.get(id);
        if (!candidate || candidate.runID !== attempt.runID || candidate.to.id !== attempt.to) this.switches.delete(id);
      }
      const due = current.switches.filter((candidate) => {
        const attempt = this.switches.get(candidate.threadID);
        if (!attempt) return !this.lastSwitchAt.has(candidate.threadID);
        return attempt.phase === 'retrying' && now >= attempt.retryAt;
      });
      if (due.length) this.deliver(due, now);
    }
    const delivering = new Set([...this.switches].filter(([, a]) => this.keepsAwake(a, now)).map(([id]) => id));
    T3.applyAccountSwitching(t3, delivering, earlierResets, now);
  }

  /** The computer stays awake until T3 starts the continued run, or delivery gives up. */
  keepsAwake(attempt, now) {
    switch (attempt.phase) {
      case 'delivering': return true;
      case 'retrying': return now < attempt.retryAt + RETRY_DELAY;
      case 'accepted': return now - attempt.acceptedAt < ACCEPTED_HOLD;
      default: return false;
    }
  }

  deliver(due, now) {
    for (const item of due) {
      const attempt = this.switches.get(item.threadID) ?? { runID: item.runID, to: item.to.id, failures: 0 };
      attempt.phase = 'delivering';
      this.switches.set(item.threadID, attempt);
      if (!this.lastSwitchAt.has(item.threadID)) this.lastSwitchAt.set(item.threadID, now);
      log(`${item.from.name} reached its usage limit: moving ${item.project} to ${item.to.name}`);
    }
    const commands = due.map((s) => ({ id: s.commandID, json: s.command }));
    dispatch(commands, T3.defaultT3Directory(), async () => this.stillWanted(due))
      .catch(() => Object.fromEntries(commands.map((c) => [c.id, { kind: 'failed', reason: "Couldn't reach T3 Code" }])))
      .then((outcomes) => this.finishDelivery(due, outcomes));
  }

  stillWanted(due) {
    const now = nowSeconds();
    const snapshot = T3.read({ now, processes: new Processes() });
    // Unreadable is not "no longer wanted": the delivery fails and is retried within the failure cap.
    if (snapshot.error || !snapshot.running) throw new Error('T3 activity unavailable');
    const current = this.switchPlan(snapshot, this.settings, now).switches;
    return new Set(due.filter((item) => current.some((c) => sameSwitch(c, item))).map((item) => item.commandID));
  }

  finishDelivery(delivered, outcomes) {
    const now = nowSeconds();
    for (const item of delivered) {
      const existing = this.switches.get(item.threadID);
      if (existing && existing.runID !== item.runID) continue;
      const attempt = existing ?? { runID: item.runID, to: item.to.id, failures: 0 };
      const outcome = outcomes[item.commandID] ?? { kind: 'failed', reason: 'No reply from T3 Code' };
      switch (outcome.kind) {
        case 'accepted':
          attempt.phase = 'accepted';
          attempt.acceptedAt = now;
          this.switchStatus = `${item.project} を ${item.to.name} に移しました`;
          this.notify('アカウントを切り替えました', `${item.from.name} が使用上限に達したため、${item.project} を ${item.to.name} に切り替えて再開しました。`);
          log(`Continued ${item.project} on ${item.to.name}`);
          break;
        case 'withdrawn':
          this.switches.delete(item.threadID);
          this.lastSwitchAt.delete(item.threadID);
          log(`Didn't move ${item.project}: it changed before the switch was sent`);
          continue;
        case 'rejected':
          attempt.phase = 'abandoned';
          this.switchStatus = `${item.project} を ${item.to.name} に移せませんでした: ${outcome.reason}`;
          log(`T3 refused to move ${item.project} to ${item.to.name}: ${outcome.reason}`);
          break;
        default:
          attempt.failures += 1;
          if (attempt.failures >= MAXIMUM_DELIVERY_FAILURES) {
            attempt.phase = 'abandoned';
            this.switchStatus = `${item.project} を ${item.to.name} に移せませんでした: ${outcome.reason}`;
            log(`Gave up moving ${item.project} to ${item.to.name}: ${outcome.reason}`);
          } else {
            attempt.phase = 'retrying';
            attempt.retryAt = now + RETRY_DELAY;
            log(`Couldn't move ${item.project} to ${item.to.name} yet: ${outcome.reason}`);
          }
      }
      this.switches.set(item.threadID, attempt);
    }
    this.evaluate();
  }

  // ---- the decision

  evaluate() {
    const settings = this.settings;
    const manualUntil = this.manualUntil;
    if (manualUntil != null && manualUntil <= nowSeconds()) {
      this.saveSetting('manualAwakeUntil', undefined);
      log('Manual sleep disable timer ended: back to automatic');
    }
    const manual = this.manualActive;
    const now = nowSeconds();
    const processes = new Processes();
    const isAlive = (pid, start) => processes.isAlive(pid, start);
    // Codex quota events are read in the background; their results count from the next evaluation.
    if (!this.codexRefreshing) {
      this.codexRefreshing = true;
      refreshCodexQuota(this.store, now, isAlive).catch(() => {}).finally(() => { this.codexRefreshing = false; });
    }
    let t3;
    try {
      t3 = this.t3Cache.resolve(T3.read({ now, processes }), now);
    } catch (error) {
      t3 = { installed: true, running: false, owner: null, accounts: [], records: [], ownedSessionIDs: new Set(),
        limitedThreads: [], limitedUntil: {}, working: 0, autoResume: null, continuationDisabled: true, error: `T3 read failed (${error.name})` };
    }
    if (t3.error && t3.error !== this.t3?.error) log(t3.error);
    // Switch decisions rewrite records; the cache keeps T3's own snapshot untouched.
    t3 = { ...t3, records: t3.records.map((r) => ({ ...r })) };
    this.t3 = t3;
    if (!t3.error) this.switchAvailable = canSwitch(t3.accounts);
    this.updateAccountSwitches(t3, settings, now);
    const contents = T3.mergeWithHooks(t3, this.store.loadAll(), processes);
    const tunables = lidSettings(settings);
    const result = evaluate(contents, now, tunables, isAlive, (file) => this.interrupts.endsWithInterrupt(file));
    for (const id of result.deadSessionIDs) {
      // A hook may have rewritten the record since it was read; only the same record is removed.
      const record = contents.records.find((r) => r.sessionID === id);
      this.store.removeIfUnchanged(record)
        .then(() => log(`Session ${shortSessionID(id)} is gone (agent process exited)`), () => {});
    }
    for (const key of result.orphanSessionKeys) this.store.removeOrphan(key, 60, now).catch(() => {});
    this.evaluation = result;
    this.blocker = this.currentBlocker(settings);
    const wakeOn = settings.wakeForQuotaReset && settings.autoEnabled && this.blocker == null;
    const plan = quotaWakePlan(wakeOn ? contents.records : [], now, isAlive);
    if (!t3.error) this.lastT3WakeAt = quotaWakePlan(t3.records, now, isAlive).nextWakeAt;
    this.nextQuotaReset = plan.nextResetAt;
    this.nextQuotaAccount = plan.nextResetAccountName;
    this.quotaHoldUntil = plan.holdUntil;
    this.quotaHoldingAccounts = plan.holdingAccountNames;
    // Failed telemetry cannot cancel a known future alarm.
    let desiredWake = plan.nextWakeAt;
    if (t3.error && wakeOn && this.lastT3WakeAt != null && this.lastT3WakeAt > now + 5) {
      desiredWake = Math.min(plan.nextWakeAt ?? this.lastT3WakeAt, this.lastT3WakeAt);
    }
    this.synchronizeWake(desiredWake);
    this.logSessionsIfChanged();
    this.updateDisplay();

    if (!this.transitioning && now >= this.retryAt) {
      const automaticHold = settings.autoEnabled && (result.keepAwake || this.quotaHoldUntil != null);
      if ((manual || automaticHold) && this.blocker == null) {
        this.pendingSleepAt = null;
        if (!this.holding) {
          this.transition(true, manual ? 'sleep disabled by hand' : this.quotaHoldUntil != null ? 'usage resets shortly' : 'an agent is working');
        }
      } else if (this.holding) {
        if (this.blocker) {
          this.pendingSleepAt = null;
          this.transition(false, Controller.describeBlocker(this.blocker));
        } else if (now >= result.sleepAllowedAt) {
          this.pendingSleepAt = null;
          this.transition(false, result.sessions.length ? 'all agents are waiting for you' : 'no agent sessions');
        } else {
          const at = result.sleepAllowedAt;
          if (at !== this.pendingSleepAt) {
            clearTimeout(this.releaseTimer);
            this.releaseTimer = setTimeout(() => this.evaluate(), Math.max(0, at - nowSeconds()) * 1000 + 50);
          }
          this.pendingSleepAt = at;
        }
      } else {
        this.pendingSleepAt = null;
      }
    }
    this.publish(settings, now);
  }

  logSessionsIfChanged() {
    const summary = this.evaluation.sessions.map((s) => `${s.accountName} · ${s.project} ${s.label}`).join('; ');
    if (summary === this.loggedSummary) return;
    this.loggedSummary = summary;
    log(`Sessions: ${summary || 'none'}`);
  }

  // ---- what the tray shows

  get headline() {
    if (this.blocker) return Controller.describeBlocker(this.blocker);
    if (this.manualActive) {
      const until = this.manualUntil;
      if (until === Infinity) return '手動でスリープを無効化中（オフにするまで）';
      return `手動でスリープを無効化中: 残り ${describeDuration(until - nowSeconds())}（${formatTime(until)} まで）`;
    }
    if (this.quotaHoldUntil != null) return `${this.quotaHoldingAccounts.join('・')} の使用量リセットに備えて起こしています`;
    if (this.holding && this.pendingSleepAt != null) {
      return `エージェントは待機中: ${Math.max(0, Math.ceil(this.pendingSleepAt - nowSeconds()))} 秒後にスリープ可`;
    }
    if (this.holding || this.evaluation.keepAwake) return 'PC を起こしています: エージェントが作業中';
    if (this.nextQuotaReset != null) return '使用量のリセット待ち: 通常のスリープ';
    return this.evaluation.sessions.length ? '全エージェントがあなたを待っています: 通常のスリープ' : 'エージェントのセッションはありません: 通常のスリープ';
  }

  get detail() {
    const lines = [];
    let first = `蓋: ${this.lidClosed ? '閉じている' : '開いている'} · スリープ: ${this.holding ? '無効' : '有効'}`;
    if (this.displayOffSent && this.lidClosed) first += ' · 画面オフ';
    lines.push(first);
    if (this.nextQuotaReset != null) lines.push(`${this.nextQuotaAccount ?? 'エージェント'} の使用量リセット: ${formatTime(this.nextQuotaReset, true)}`);
    for (const message of [this.wakeError, this.t3?.error, this.switchStatus, this.lastError]) if (message) lines.push(message);
    return lines;
  }

  get icon() {
    if (this.blocker) return this.blocker.kind === 'paused' ? 'pause' : 'warning';
    if (this.manualActive) return this.manualUntil === Infinity ? 'sun' : 'timer';
    if (this.holding) return this.pendingSleepAt == null ? 'cup' : 'hourglass';
    return 'moon';
  }

  switchInfo() {
    const t3 = this.t3;
    if (!t3?.installed) return { reason: 'T3 Code が見つかりません', accounts: '' };
    const groups = {};
    for (const account of t3.accounts) {
      if (account.configured && account.enabled !== false) (groups[account.driver] ??= []).push(account);
    }
    const now = nowSeconds();
    const lines = Object.values(groups).filter((g) => g.length > 1).map((accounts) => accounts.map((a) => {
      const until = t3.limitedUntil[a.id];
      return until != null && until > now ? `${a.name}（制限中 〜${formatTime(until)}）` : a.name;
    }).join(' / '));
    if (t3.autoResume === false) return { reason: 'T3 Code の自動再開がオフのため使えません', accounts: lines.join('\n') };
    if (!lines.length) return { reason: '同じツールのアカウントが T3 Code に 2 つ以上必要です', accounts: '' };
    return { reason: null, accounts: `切替先: ${lines.join('\n')}` };
  }

  publish(settings, now) {
    if (now - this.integrationsAt > 60) {
      try { this.integrations = Hooks.hookFiles(); } catch { this.integrations = []; }
      this.integrationsAt = now;
    }
    const t3 = this.t3;
    const info = this.switchInfo();
    const effective = { ...DEFAULTS, ...settings, startAtLogin: fs.existsSync(startupShortcut()) };
    const t3Text = !t3?.installed ? '見つかりません' : !t3.running ? '起動していません（起動すると直接追跡します）'
      : t3.error ? t3.error : `会話を直接追跡しています（作業中 ${t3.working} 件）`;
    const battery = this.power.battery != null ? `バッテリー ${this.power.battery}%${this.power.onBattery ? '' : '（電源接続）'}` : 'バッテリーなし';
    const status = {
      type: 'status',
      headline: this.headline,
      detail: this.detail,
      icon: this.icon,
      sessions: this.evaluation.sessions.map((s) => ({ id: s.id, text: `${s.accountName} · ${s.project}: ${s.label} · ${age(s.since)}`, keepsAwake: s.keepsAwake })),
      settings: effective,
      manualActive: this.manualActive,
      holding: this.holding,
      switchAvailable: this.switchAvailable === true,
      switchUnavailableReason: info.reason,
      switchAccountsText: info.accounts,
      t3Installed: t3?.installed === true,
      autoResume: t3?.autoResume ?? null,
      t3Text,
      powerText: `蓋を閉じても起きたままにできます（作業中だけ「蓋を閉じたときの動作」を一時的に「何もしない」にします）。${battery}`,
      integrations: this.integrations,
      events: this.events,
    };
    const text = JSON.stringify(status);
    // Lets the tray notice a watcher that stopped answering while sleep is held.
    this.send({ type: 'heartbeat' });
    if (text !== this.lastStatus) {
      this.lastStatus = text;
      this.send(status);
      try { writeJSONAtomic(paths.status, { ...status, pid: process.pid, updatedAt: now }); } catch { /* next tick */ }
    }
  }
}

