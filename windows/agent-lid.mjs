#!/usr/bin/env node
// Agent Lid Closed for Windows: the decision side. AgentLidClosed.exe (the notification-area app)
// starts `run --tray` and exchanges JSON lines with it over stdin/stdout.
//
//   node agent-lid.mjs run --tray          used by AgentLidClosed.exe
//   node agent-lid.mjs run --dry-run       decide without a tray; power changes are only logged
//   node agent-lid.mjs status              print sessions and the sleep decision
//   node agent-lid.mjs plan                print the T3 account switches it would make now
//   node agent-lid.mjs set switch on|off   switch T3 accounts at usage limits
//   node agent-lid.mjs set auto-resume on|off   T3's native continuation after a reset
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { Controller } from './lib/controller.mjs';
import { plan as planSwitches } from './lib/planner.mjs';
import * as T3 from './lib/t3.mjs';
import { Processes } from './lib/process.mjs';
import { SessionStore } from './lib/sessions.mjs';
import { evaluate, lidSettings } from './lib/evaluator.mjs';
import { endsWithInterrupt } from './lib/transcript.mjs';
import { refreshCodexQuota } from './lib/codexQuota.mjs';
import { loadAppSettings, log, saveAppSetting, setT3AutoResume, stateDirectory } from './lib/settings.mjs';

const nowSeconds = () => Date.now() / 1000;

/** The lock holds the PID and its start time, so a reused PID can't keep the watcher from starting. */
function ensureSingleInstance() {
  const lock = path.join(stateDirectory(), 'daemon.pid');
  const processes = new Processes();
  const self = processes.identity(process.pid);
  const mine = `${process.pid} ${self?.startTime ?? 0}`;
  fs.mkdirSync(stateDirectory(), { recursive: true });
  // Created exclusively, so two watchers starting together can't both win.
  for (let attempt = 0; ; attempt += 1) {
    try {
      fs.writeFileSync(lock, mine, { flag: 'wx' });
      break;
    } catch (error) {
      if (error.code !== 'EEXIST' || attempt >= 2) throw error;
    }
    let pid = 0;
    let start = 0;
    try { [pid, start] = fs.readFileSync(lock, 'utf8').trim().split(' ').map(Number); } catch { /* removed meanwhile */ }
    const alive = pid > 0 && processes.isAlive(pid, start || 0);
    if (alive) {
      console.error(`Already running (pid ${pid})`);
      process.exit(0);
    }
    // A stale lock from a watcher that was killed: remove it and try again.
    try { fs.unlinkSync(lock); } catch { /* another starter removed it */ }
  }
  process.on('exit', () => {
    try {
      if (fs.readFileSync(lock, 'utf8') === mine) fs.unlinkSync(lock);
    } catch { /* ignore */ }
  });
}

function run(tray) {
  ensureSingleInstance();
  process.on('uncaughtException', (error) => {
    log(`Crashed: ${error?.stack ?? error}`);
    process.exit(1);
  });
  const send = tray ? (message) => { process.stdout.write(`${JSON.stringify(message)}\n`); } : () => {};
  const controller = new Controller({ send, tray });
  if (tray) {
    const input = readline.createInterface({ input: process.stdin });
    input.on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      controller.handle(message);
    });
    // The tray went away: it already released the hold on its side.
    input.on('close', () => {
      log('Tray closed');
      process.exit(0);
    });
  } else {
    const stop = () => controller.shutdown().finally(() => process.exit(0));
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
  }
  controller.start();
}

async function printStatus() {
  const now = nowSeconds();
  const processes = new Processes();
  const isAlive = (pid, start) => processes.isAlive(pid, start);
  const store = new SessionStore();
  await refreshCodexQuota(store, now, isAlive);
  const t3 = T3.read({ now, processes });
  if (t3.error) console.error(t3.error);
  const settings = loadAppSettings();
  const result = evaluate(T3.mergeWithHooks(t3, store.loadAll(), processes), now, lidSettings(settings), isAlive, endsWithInterrupt);
  if (!result.sessions.length) console.log('エージェントのセッションはありません');
  for (const session of result.sessions) {
    const minutes = Math.floor((now - session.since) / 60);
    console.log(`${session.accountName} · ${session.project}  ${session.label}  (${minutes} 分)  ${session.id}`);
  }
  for (const id of result.deadSessionIDs) console.log(`${id}  プロセス終了`);
  if (result.keepAwake) {
    console.log('=> PC を起こしておく');
  } else {
    const wait = Math.ceil(Math.max(0, result.sleepAllowedAt - now));
    console.log(wait === 0 ? '=> スリープしてよい' : `=> ${wait} 秒後にスリープしてよい`);
  }
}

function parseSwitch(value) {
  if (['on', 'true', '1'].includes(value)) return true;
  if (['off', 'false', '0'].includes(value)) return false;
  console.error('Expected on or off');
  process.exit(2);
}

const [command = 'run', ...args] = process.argv.slice(2);
switch (command) {
  case 'run':
    run(args.includes('--tray'));
    break;
  case 'status':
    await printStatus();
    break;
  case 'plan': {
    const now = nowSeconds();
    const snapshot = T3.read({ now, processes: new Processes() });
    const settings = loadAppSettings();
    const current = settings.switchAccountAtLimit === false ? { switches: [], earlierResets: {} } : planSwitches({
      threads: snapshot.limitedThreads, accounts: snapshot.accounts, limitedUntil: snapshot.limitedUntil,
      now, continuationDisabled: snapshot.continuationDisabled,
    });
    console.log(JSON.stringify({
      limitedThreads: snapshot.limitedThreads.map(({ modelSelection, record, ...rest }) => rest),
      limitedUntil: snapshot.limitedUntil,
      switches: current.switches.map((s) => ({ project: s.project, from: s.from.name, to: s.to.name, commandID: s.commandID })),
      earlierResets: current.earlierResets,
      error: snapshot.error,
    }, null, 2));
    break;
  }
  case 'set': {
    const [key, value] = args;
    if (key === 'switch') {
      const enabled = parseSwitch(value);
      saveAppSetting('switchAccountAtLimit', enabled);
      log(`Switch accounts at usage limits ${enabled ? 'on' : 'off'}`);
    } else if (key === 'auto-resume') {
      const enabled = parseSwitch(value);
      try {
        // The installer passes --preserve: an explicit opt-out in T3 is kept, as on macOS.
        const result = setT3AutoResume(path.join(T3.defaultT3Directory(), 'settings.json'), enabled,
          { preserveChoice: args.includes('--preserve') });
        if (result === 'missing') {
          console.error('T3 Code settings not found');
          process.exit(1);
        }
        log(`T3 auto-resume ${enabled ? 'on' : 'off'}`);
      } catch (error) {
        console.error(`Could not configure T3 auto-resume (${error.message})`);
        process.exit(1);
      }
    } else {
      console.error('Usage: set switch|auto-resume on|off');
      process.exit(2);
    }
    break;
  }
  case 'hooks': {
    // Used by install.ps1 / uninstall.ps1, like scripts/hooks.py.
    const Hooks = await import('./lib/hooks.mjs');
    const { hookScript } = await import('./lib/controller.mjs');
    const action = args[0];
    const option = (name) => args.includes(name);
    const claudeDirs = args.flatMap((a, i) => (a === '--claude-config-dir' && args[i + 1] ? [args[i + 1]] : []));
    if (action === 'install') {
      const planned = Hooks.plan({ claudeDirs, noClaude: option('--no-claude'), noCodex: option('--no-codex'), forceCodex: option('--codex') });
      for (const provider of ['claude', 'codex']) {
        for (const file of planned[provider]) {
          try {
            Hooks.apply('install', file, { provider, hookScript });
            console.log(`${provider === 'claude' ? 'Claude Code' : 'Codex'}: フックを追加しました ${file}`);
          } catch (error) {
            console.error(`${file}: ${error.message}（そのままにしました）`);
            process.exitCode = 1;
          }
        }
      }
      if (!planned.claude.length && !planned.codex.length) console.log('Claude Code も Codex も見つからないため、フックは追加していません');
    } else if (action === 'uninstall') {
      for (const { provider, file } of Hooks.targets()) {
        try {
          Hooks.apply('uninstall', file, { provider });
          console.log(`フックを削除しました ${file}`);
        } catch (error) {
          console.error(`${file}: ${error.message}`);
          process.exitCode = 1;
        }
      }
    } else {
      console.error('Usage: hooks install [--no-claude] [--no-codex] [--codex] [--claude-config-dir DIR]... | hooks uninstall');
      process.exit(2);
    }
    break;
  }
  default:
    console.error('Usage: agent-lid.mjs [run --tray|run --dry-run|status|plan|hooks|set switch|auto-resume on|off]');
    process.exit(2);
}
