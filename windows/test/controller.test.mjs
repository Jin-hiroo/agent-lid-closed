// Like scripts/test-display.py and test-manual.py: drives the Controller with a fake tray and checks
// the power messages it sends. No real power settings change.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-lid-controller-'));
process.env.AGENT_LID_STATE_DIR = temporary;
process.env.AGENT_LID_T3_DIR = path.join(temporary, 't3-none');
process.env.AGENT_LID_HOME = path.join(temporary, 'home');
process.env.AGENT_LID_EXE = path.join(temporary, 'missing.exe');

const { Controller } = await import('../lib/controller.mjs');
const { SessionStore } = await import('../lib/sessions.mjs');
const { writeJSONAtomic, paths } = await import('../lib/settings.mjs');

writeJSONAtomic(paths.settings, { sleepGraceSeconds: 0, notifyTimeoutSeconds: 0 });
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fakeTray() {
  const sent = [];
  let controller;
  const send = (message) => {
    sent.push(message);
    // The tray answers power requests the way AgentLidClosed.exe does.
    if (message.type === 'hold') {
      setImmediate(() => controller.handle({ type: 'holdResult', id: message.id, ok: true, holding: message.hold }));
    } else if (message.type === 'wake') {
      setImmediate(() => controller.handle({ type: 'wakeResult', id: message.id, ok: true, armedAt: message.at }));
    }
  };
  controller = new Controller({ send, tray: true });
  return { controller, sent, of: (type) => sent.filter((m) => m.type === type) };
}

test('holds while an agent works, then releases and sleeps with the lid closed', async () => {
  const { controller, of } = fakeTray();
  const store = new SessionStore();
  const now = Date.now() / 1000;
  store.save({ sessionID: 's1', state: 'working', reason: 'working', notified: false, stateSince: now, updatedAt: now,
    pid: 0, pidStart: 0, provider: 'claude', cwd: 'C:\\work\\demo' });
  controller.handle({ type: 'power', lidClosed: true, onBattery: false, battery: 90, externalDisplay: false, holding: false });
  controller.evaluate();
  await wait(50);
  assert.deepEqual(of('hold').map((m) => m.hold), [true]);
  assert.match(of('status').at(-1).detail[0], /画面オフ/, 'Windows turns the built-in display off with the lid closed');
  const status = of('status').at(-1);
  assert.equal(status.icon, 'cup');
  assert.match(status.sessions[0].text, /Claude · demo: 作業中/);

  store.save({ ...store.load('s1'), state: 'waiting', reason: 'finished', notified: true, updatedAt: Date.now() / 1000 - 1 });
  controller.evaluate();
  await wait(50);
  assert.deepEqual(of('hold').map((m) => m.hold), [true, false]);
  assert.equal(of('sleepNow').length, 1, 'lid closed and everyone waiting: sleep now');
  assert.equal(of('status').at(-1).icon, 'moon');
  // The tray confirms right before suspending; the answer reflects the latest state.
  controller.handle({ type: 'confirmSleep', id: 7 });
  assert.deepEqual(of('sleepConfirmed').at(-1), { type: 'sleepConfirmed', id: 7, ok: true });
  store.save({ ...store.load('s1'), state: 'working', reason: 'working', updatedAt: Date.now() / 1000 });
  controller.handle({ type: 'confirmSleep', id: 8 });
  assert.deepEqual(of('sleepConfirmed').at(-1), { type: 'sleepConfirmed', id: 8, ok: false }, 'an agent started meanwhile');
  await wait(50);
  store.remove('s1');
  clearInterval(controller.ticker);
});

test('no explicit sleep with an external display; low battery releases the hold', async () => {
  const { controller, of } = fakeTray();
  const store = new SessionStore();
  const now = Date.now() / 1000;
  store.save({ sessionID: 's1', state: 'working', reason: 'working', notified: false, stateSince: now, updatedAt: now, pid: 0, pidStart: 0 });
  controller.handle({ type: 'power', lidClosed: true, onBattery: true, battery: 50, externalDisplay: true, holding: false });
  controller.evaluate();
  await wait(50);
  assert.deepEqual(of('hold').map((m) => m.hold), [true]);
  assert.doesNotMatch(of('status').at(-1).detail[0], /画面オフ/, 'an external display stays on');
  controller.handle({ type: 'power', lidClosed: true, onBattery: true, battery: 10, externalDisplay: true, holding: true });
  controller.evaluate();
  await wait(50);
  assert.deepEqual(of('hold').map((m) => m.hold), [true, false]);
  assert.equal(of('sleepNow').length, 0);
  assert.equal(of('status').at(-1).icon, 'warning');
  store.remove('s1');
  clearInterval(controller.ticker);
});

test('manual hold works with Automatic Mode off and ends on time', async () => {
  const { controller, of } = fakeTray();
  controller.handle({ type: 'power', lidClosed: false, onBattery: false, battery: 90, externalDisplay: false, holding: false });
  controller.command({ name: 'set', key: 'autoEnabled', value: false });
  await wait(30);
  assert.equal(of('status').at(-1).icon, 'pause');
  controller.command({ name: 'manual', seconds: 1 });
  await wait(50);
  assert.deepEqual(of('hold').map((m) => m.hold), [true]);
  assert.equal(of('status').at(-1).icon, 'timer');
  await wait(1200);
  assert.deepEqual(of('hold').map((m) => m.hold), [true, false]);
  controller.command({ name: 'manual' });
  await wait(30);
  assert.equal(of('status').at(-1).icon, 'sun');
  controller.command({ name: 'manualOff' });
  controller.command({ name: 'set', key: 'autoEnabled', value: true });
  await wait(30);
  assert.equal(of('hold').at(-1).hold, false);
  clearInterval(controller.ticker);
  clearTimeout(controller.manualTimer);
});

test('a usage limit schedules a wake two minutes before the reset', async () => {
  const { controller, of } = fakeTray();
  const store = new SessionStore();
  const now = Date.now() / 1000;
  store.save({ sessionID: 'q', state: 'waiting', reason: 'usage limit', notified: true, stateSince: now, updatedAt: now,
    pid: process.pid, pidStart: 0, provider: 'claude', quotaWaitSince: now, quotaResetAt: now + 3600 });
  controller.handle({ type: 'power', lidClosed: false, onBattery: false, battery: 90, externalDisplay: false, holding: false });
  controller.evaluate();
  await wait(50);
  assert.equal(of('wake').at(-1).at, Math.floor(now + 3600 - 120));
  assert.match(of('status').at(-1).detail.join('\n'), /Claude の使用量リセット/);
  controller.command({ name: 'set', key: 'wakeForQuotaReset', value: false });
  await wait(50);
  assert.equal(of('wake').at(-1).at, null, 'turning the option off clears the alarm');
  store.remove('q');
  clearInterval(controller.ticker);
});
