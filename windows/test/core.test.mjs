// Ports of the hook, evaluator, quota, transcript and installer checks in scripts/test-*.{sh,py}
// and Tests/QuotaChecks.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-lid-core-'));
process.env.AGENT_LID_STATE_DIR = temporary;
process.env.AGENT_LID_HOME = path.join(temporary, 'home');

const { SessionStore, applyHook, hookAction, parseHookInput, saveStatusLine } = await import('../lib/sessions.mjs');
const { evaluate, lidSettings, parseDuration, quotaWakePlan, describeDuration } = await import('../lib/evaluator.mjs');
const { endsWithInterrupt } = await import('../lib/transcript.mjs');
const { refreshCodexQuota } = await import('../lib/codexQuota.mjs');
const Hooks = await import('../lib/hooks.mjs');

const now = 2_000_000_000;
const alive = () => true;
const settings = lidSettings({});

function freshStore(name) {
  return new SessionStore(path.join(temporary, name));
}

async function fire(store, payload, { provider = 'claude', at = now, owner = { pid: 100, startTime: 1 } } = {}) {
  const input = parseHookInput(payload);
  input.sessionID = provider === 'codex' ? `codex:${input.sessionID}` : input.sessionID;
  await store.withLock(() => applyHook(hookAction(input, provider), input, owner, store, at, provider));
  return store.load(input.sessionID);
}

test('hook events map to states as on macOS', () => {
  const action = (payload, provider) => hookAction(parseHookInput({ session_id: 's', ...payload }), provider);
  assert.deepEqual(action({ hook_event_name: 'UserPromptSubmit' }), { kind: 'set', state: 'working', reason: 'working', notified: false });
  assert.equal(action({ hook_event_name: 'PreToolUse', tool_name: 'AskUserQuestion' }).reason, 'question');
  assert.equal(action({ hook_event_name: 'PreToolUse', tool_name: 'functions.request_user_input' }, 'codex').state, 'waiting');
  assert.equal(action({ hook_event_name: 'PermissionRequest' }, 'codex').state, 'working');
  assert.equal(action({ hook_event_name: 'PermissionRequest' }).kind, 'ignore');
  assert.equal(action({ hook_event_name: 'Notification', notification_type: 'permission_prompt' }).reason, 'permission');
  assert.equal(action({ hook_event_name: 'Notification', notification_type: 'idle_prompt' }).reason, null);
  assert.equal(action({ hook_event_name: 'Stop', background_tasks: [{ status: 'running' }] }).state, 'background');
  assert.equal(action({ hook_event_name: 'Stop', background_tasks: [{ status: 'completed' }] }).state, 'waiting');
  assert.equal(action({ hook_event_name: 'Stop' }, 'codex').notified, true);
  assert.equal(action({ hook_event_name: 'StopFailure', error: 'rate_limit' }).reason, 'usage limit');
  assert.equal(action({ hook_event_name: 'SessionStart', source: 'compact' }).kind, 'keepState');
  assert.equal(action({ hook_event_name: 'PreToolUse', agent_id: 'a1' }).kind, 'subagentActive');
  assert.equal(action({ hook_event_name: 'SessionEnd' }).kind, 'endSession');
  assert.equal(parseHookInput({ hook_event_name: 'Stop' }), null, 'session ID is required');
});

test('hooks keep the owner, cwd and state history', async () => {
  const store = freshStore('history');
  let record = await fire(store, { hook_event_name: 'SessionStart', session_id: 's1', cwd: 'C:\\work\\demo', source: 'startup' });
  assert.equal(record.state, 'waiting');
  assert.equal(record.cwd, 'C:\\work\\demo');
  record = await fire(store, { hook_event_name: 'UserPromptSubmit', session_id: 's1' }, { owner: null, at: now + 1 });
  assert.equal(record.state, 'working');
  assert.equal(record.pid, 100, 'a hook without an owner lookup keeps the known owner');
  assert.equal(record.cwd, 'C:\\work\\demo');
  record = await fire(store, { hook_event_name: 'PostToolUse', session_id: 's1' }, { owner: null, at: now + 5 });
  assert.equal(record.stateSince, now + 1, 'same state keeps its start');
  assert.equal(record.updatedAt, now + 5);
  await fire(store, { hook_event_name: 'SubagentStart', session_id: 's1', agent_id: 'a1' });
  assert.equal(Object.keys(store.loadAll().agentActivity).length, 1);
  await fire(store, { hook_event_name: 'SubagentStop', session_id: 's1', agent_id: 'a1' });
  assert.equal(Object.keys(store.loadAll().agentActivity).length, 0);
  await fire(store, { hook_event_name: 'SessionEnd', session_id: 's1' });
  assert.equal(store.load('s1'), null);
});

test('a delayed Codex hook from an interrupted turn cannot replace its successor', async () => {
  const store = freshStore('codex-turns');
  await fire(store, { hook_event_name: 'UserPromptSubmit', session_id: 'c', turn_id: 't2' }, { provider: 'codex' });
  const record = await fire(store, { hook_event_name: 'Stop', session_id: 'c', turn_id: 't1' }, { provider: 'codex', at: now + 3 });
  assert.equal(record.state, 'working');
});

test('Claude usage limit: status-line windows arm the reset', async () => {
  const store = freshStore('quota');
  await fire(store, { hook_event_name: 'UserPromptSubmit', session_id: 'q' });
  await saveStatusLine({ session_id: 'q', rate_limits: { five_hour: { used_percentage: 100, resets_at: now + 3600 } } }, store, now + 1);
  const record = await fire(store, { hook_event_name: 'StopFailure', session_id: 'q', error: 'rate_limit' }, { at: now + 2 });
  assert.equal(record.reason, 'usage limit');
  assert.equal(record.quotaWaitSince, now + 2);
  assert.equal(record.quotaResetAt, now + 3600);
  const plan = quotaWakePlan([record], now + 2, alive);
  assert.equal(plan.nextWakeAt, now + 3600 - 120);
  const holding = quotaWakePlan([record], now + 3600 - 60, alive);
  assert.equal(holding.holdUntil, now + 3600 + 300);
  assert.deepEqual(holding.holdingAccountNames, ['Claude']);
  const after = await fire(store, { hook_event_name: 'UserPromptSubmit', session_id: 'q' }, { at: now + 3700 });
  assert.equal(after.quotaResetAt, null, 'new work clears the wait');
});

test('evaluation: grace periods, notifications, stale work, subagents and dead sessions', () => {
  const base = { pid: 0, pidStart: 0, provider: 'claude', notified: false };
  const contents = {
    records: [
      { ...base, sessionID: 'waitingNotified', state: 'waiting', reason: 'permission', notified: true, stateSince: now - 5, updatedAt: now - 5 },
      { ...base, sessionID: 'waitingForNotice', state: 'waiting', reason: 'finished', stateSince: now - 10, updatedAt: now - 10 },
    ],
    agentActivity: {},
  };
  let result = evaluate(contents, now, settings, alive, () => false);
  assert.equal(result.keepAwake, false);
  assert.equal(result.sleepAllowedAt, now - 10 + 90, 'waits for Claude\'s delayed notification');
  contents.records.push({ ...base, sessionID: 'working', state: 'working', reason: 'working', stateSince: now - 60, updatedAt: now - 60 });
  result = evaluate(contents, now, settings, alive, () => false);
  assert.equal(result.keepAwake, true);
  assert.equal(result.sessions[0].id, 'working');
  result = evaluate(contents, now + 31 * 60, settings, alive, () => false);
  assert.equal(result.sessions.find((s) => s.id === 'working').activity.kind, 'stale');
  result = evaluate(contents, now, settings, alive, (file) => file === 'interrupted.jsonl');
  contents.records[2].transcriptPath = 'interrupted.jsonl';
  result = evaluate(contents, now, settings, alive, (file) => file === 'interrupted.jsonl');
  assert.equal(result.sessions.find((s) => s.id === 'working').activity.kind, 'interrupted');
  const withAgents = { records: [contents.records[0]], agentActivity: { waitingNotified: [now - 10] } };
  assert.equal(evaluate(withAgents, now, settings, alive, () => false).sessions[0].activity.kind, 'subagents');
  const dead = { records: [{ ...contents.records[0], pid: 42, pidStart: 1 }], agentActivity: {} };
  assert.deepEqual(evaluate(dead, now, settings, () => false, () => false).deadSessionIDs, ['waitingNotified']);
});

test('typed durations, as on macOS', () => {
  assert.equal(parseDuration('90'), 5400);
  assert.equal(parseDuration('1:30'), 5400);
  assert.equal(parseDuration('2h'), 7200);
  assert.equal(parseDuration('1h 30m'), 5400);
  assert.equal(parseDuration('1.5h'), 5400);
  assert.equal(parseDuration('2 hours 10 min'), 7800);
  for (const bad of ['', '0', '1:5', 'abc', '8d', '1x', '-5', '200h']) assert.equal(parseDuration(bad), null, bad);
  assert.equal(describeDuration(5400), '1 時間 30 分');
  assert.equal(describeDuration(20), '20 秒');
});

test('Claude interrupt marker in the transcript', () => {
  const file = path.join(temporary, 'transcript.jsonl');
  fs.writeFileSync(file, [
    JSON.stringify({ type: 'assistant', message: { content: 'hi' } }),
    JSON.stringify({ type: 'user', message: { content: [{ type: 'text', text: '[Request interrupted by user]' }] } }),
  ].join('\n') + '\n');
  assert.equal(endsWithInterrupt(file), true);
  fs.appendFileSync(file, `${JSON.stringify({ type: 'assistant', message: { content: 'again' } })}\n`);
  assert.equal(endsWithInterrupt(file), false);
});

test('Codex event log: a quota error with known windows arms the reset', async () => {
  const store = freshStore('codex-quota');
  const log = path.join(temporary, 'rollout.jsonl');
  const at = (s) => new Date((now + s) * 1000).toISOString();
  fs.writeFileSync(log, [
    { timestamp: at(1), type: 'event_msg', payload: { type: 'task_started', turn_id: 't1' } },
    { timestamp: at(2), type: 'event_msg', payload: { type: 'token_count', rate_limits: { primary: { used_percent: 100, resets_at: now + 1800 } } } },
    { timestamp: at(3), type: 'event_msg', payload: { type: 'error', codex_error_info: 'usage_limit_exceeded', turn_id: 't1' } },
  ].map((e) => JSON.stringify(e)).join('\n') + '\n');
  store.save({ sessionID: 'codex:c', state: 'working', reason: 'working', notified: false, stateSince: now, updatedAt: now,
    pid: 5, pidStart: 1, provider: 'codex', transcriptPath: log, turnID: 't1' });
  await refreshCodexQuota(store, now + 10, alive);
  const record = store.load('codex:c');
  assert.equal(record.reason, 'usage limit');
  assert.equal(record.quotaResetAt, now + 1800);
  assert.ok(record.codexTranscriptOffset > 0);
  await refreshCodexQuota(store, now + 20, alive);
  assert.equal(store.load('codex:c').quotaResetAt, now + 1800, 'a re-read does not replay or reset');
});

test('installer adds and removes hooks, keeping other hooks and the status line', () => {
  const file = path.join(temporary, 'claude-settings.json');
  const manifest = path.join(temporary, 'manifest.json');
  const original = { theme: 'dark', statusLine: { type: 'command', command: 'echo "hi"', padding: 2 },
    hooks: { Stop: [{ hooks: [{ type: 'command', command: 'other-tool' }] }] } };
  fs.writeFileSync(file, JSON.stringify(original));
  Hooks.apply('install', file, { provider: 'claude', hookScript: 'C:\\Apps\\Agent Lid\\agent-lid-hook.mjs', manifest });
  const installed = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(installed.hooks.Stop.length, 2);
  assert.equal(installed.hooks.PreToolUse[0].matcher, '*');
  assert.equal(installed.hooks.Stop[1].hooks[0].command, 'node "C:/Apps/Agent Lid/agent-lid-hook.mjs"');
  assert.match(installed.statusLine.command, /statusline --original-b64 [A-Za-z0-9+/=]+$/);
  assert.equal(installed.statusLine.padding, 2);
  assert.ok(Hooks.hasHooks(file));
  assert.deepEqual(Hooks.readManifest(manifest).claude, [path.resolve(file)]);
  Hooks.apply('install', file, { provider: 'claude', hookScript: 'C:/x/agent-lid-hook.mjs', manifest });
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).hooks.Stop.length, 2, 'reinstalling replaces, not duplicates');
  Hooks.apply('uninstall', file, { manifest });
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), original);
  assert.deepEqual(Hooks.readManifest(manifest).claude, []);
  const codex = path.join(temporary, 'codex', 'hooks.json');
  Hooks.apply('install', codex, { provider: 'codex', hookScript: 'C:/x/agent-lid-hook.mjs', manifest });
  const codexHooks = JSON.parse(fs.readFileSync(codex, 'utf8'));
  assert.equal(codexHooks.hooks.Interrupt[0].hooks[0].command, 'node "C:/x/agent-lid-hook.mjs" --provider codex');
  assert.equal(codexHooks.statusLine, undefined);
  assert.throws(() => { fs.writeFileSync(file, '{"hooks": []}'); Hooks.apply('install', file, { hookScript: 'x', manifest }); });
});

test('the session lock admits one holder at a time and frees itself', async () => {
  const store = freshStore('locks');
  let inside = 0;
  let overlap = false;
  await Promise.all(Array.from({ length: 5 }, () => store.withLock(async () => {
    inside += 1;
    if (inside > 1) overlap = true;
    await new Promise((resolve) => setTimeout(resolve, 20));
    inside -= 1;
  })));
  assert.equal(overlap, false);
  assert.equal(await store.withLock(() => 'ran'), 'ran');
});
