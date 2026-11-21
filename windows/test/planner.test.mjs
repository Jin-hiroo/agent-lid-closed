// Port of the account-switching checks in Tests/QuotaChecks/main.swift.
import test from 'node:test';
import assert from 'node:assert/strict';
import { canSwitch, plan } from '../lib/planner.mjs';
import { accountsFrom, parseSettings } from '../lib/t3.mjs';

const now = 2_000_000_000;
const account = (id, driver, name, extra = {}) => ({
  id, driver, name, enabled: true, projectEnabled: {}, configured: true, customModels: [], ...extra,
});
const main = account('claudeAgent', 'claudeAgent', 'Claude');
const second = account('claudeAgent_second', 'claudeAgent', 'Claude - Second');
const chatGPT = account('codex-personal', 'codex', 'Codex');
const selection = '{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"xhigh"}]}';

function limited({ failedAt = now - 30, reset = now + 3600, autoResume = null, snoozedUntil = null, delegated = false,
  accountID = 'claudeAgent', modelSelection = selection, projectID = null } = {}) {
  return {
    threadID: 'thread', runID: 'run-1', projectID, accountID, failedAt, resetAt: reset, snoozedUntil, autoResume,
    isDelegated: delegated, modelSelection, cwd: 'C:\\Users\\me\\project',
  };
}
const switchPlan = (threads, accounts = [main, second, chatGPT], limitedUntil = { claudeAgent: now + 3600 }, at = now) =>
  plan({ threads, accounts, limitedUntil, now: at });

test('switches to the other account of the same tool, as T3 Resume does', () => {
  const moved = switchPlan([limited()]);
  assert.deepEqual(moved.switches.map((s) => s.to.id), ['claudeAgent_second']);
  assert.equal(moved.switches[0].project, 'project');
  const command = JSON.parse(moved.switches[0].command);
  assert.equal(command.type, 'message.dispatch');
  assert.equal(command.manualContinuationOfRunId, 'run-1');
  assert.equal(command.commandId, 'agent-lid-account-switch:thread:run-1');
  assert.equal(command.messageId, command.commandId);
  assert.equal(command.modelSelection.instanceId, 'claudeAgent_second');
  assert.equal(command.modelSelection.model, 'claude-opus-5-5');
  assert.equal(command.modelSelection.options[0].value, 'xhigh');
  assert.equal(command.dispatchMode.type, 'start_immediately');
  assert.equal(command.createdBy, 'user');
  assert.match(command.text, /Claude - Second/);
});

test('skips switches T3 or the user would not want', () => {
  assert.equal(switchPlan([limited()], [main, chatGPT]).switches.length, 0, 'never another tool');
  assert.equal(switchPlan([limited()], [main, { ...second, enabled: false }]).switches.length, 0, 'disabled account');
  assert.equal(switchPlan([limited({ delegated: true })]).switches.length, 0, 'delegated child');
  assert.equal(switchPlan([limited({ autoResume: false })]).switches.length, 0, 'declined recovery');
  assert.equal(switchPlan([limited({ snoozedUntil: now + 60 })]).switches.length, 0, 'snoozed');
  assert.equal(switchPlan([limited({ failedAt: now - 3600 })]).switches.length, 0, 'old unarmed failure');
  assert.equal(switchPlan([limited({ failedAt: now - 3600, autoResume: true })]).switches.length, 1, 'armed at any age');
  assert.equal(switchPlan([limited({ modelSelection: '{}' })]).switches.length, 0, 'unreadable selection');
  assert.equal(switchPlan([limited()], [main, { ...second, configured: false }]).switches.length, 0, 'unconfigured built-in');
  assert.equal(plan({ threads: [limited()], accounts: [main, second], limitedUntil: {}, now, continuationDisabled: true })
    .switches.length, 0, 'global opt-out');
  assert.equal(switchPlan([limited()], [{ ...main, customModels: ['claude-opus-5-5'] }, second]).switches.length, 0,
    'custom model must exist on the target');
});

test('project overrides', () => {
  const projectOff = { ...second, projectEnabled: { 'project-a': false } };
  assert.equal(switchPlan([limited({ projectID: 'project-a' })], [main, projectOff]).switches.length, 0);
  assert.equal(switchPlan([limited({ projectID: 'project-b' })], [main, projectOff]).switches.length, 1);
});

test('both accounts limited: waits for whichever resets first', () => {
  const moved = switchPlan([limited({ reset: now + 7200 })], undefined,
    { claudeAgent: now + 7200, claudeAgent_second: now + 1800 });
  assert.equal(moved.switches.length, 0);
  assert.deepEqual(moved.earlierResets.thread, { at: now + 1860, accountName: 'Claude - Second' });
  assert.deepEqual(switchPlan([limited({ reset: now + 1800 })], undefined, { claudeAgent_second: now + 7200 }).earlierResets, {});
  assert.equal(switchPlan([limited()], undefined, { claudeAgent_second: now - 30 }).switches.length, 0, 'reset margin');
  assert.equal(switchPlan([limited()], undefined, { claudeAgent_second: now - 61 }).switches.length, 1, 'after reset');
});

test('reads accounts from T3 settings like the macOS app', () => {
  const settings = parseSettings({
    providerInstances: {
      claudeAgent: { driver: 'claudeAgent', enabled: true },
      claudeAccount2: { driver: 'claudeAgent', displayName: 'Account 2', config: { customModels: [{ slug: 'x' }, 'y'] } },
      off: { driver: 'claudeAgent', displayName: 'Off', config: { enabled: false } },
      other: { driver: 'gemini' },
    },
    projectSettingsOverrides: { p: { providerInstances: { claudeAccount2: { enabled: false } } } },
    autoResumeLimitedThreads: true,
  });
  const accounts = accountsFrom(settings);
  assert.deepEqual(accounts.map((a) => a.id), ['claudeAccount2', 'claudeAgent', 'codex', 'off']);
  const second2 = accounts.find((a) => a.id === 'claudeAccount2');
  assert.equal(second2.name, 'Claude (Account 2)');
  assert.deepEqual(second2.customModels, ['x', 'y']);
  assert.deepEqual(second2.projectEnabled, { p: false });
  assert.equal(accounts.find((a) => a.id === 'off').enabled, false);
  assert.equal(accounts.find((a) => a.id === 'codex').configured, false);
  assert.equal(settings.autoResumeLimitedThreads, true);
  assert.equal(canSwitch(accounts), true);
  assert.equal(canSwitch(accounts.filter((a) => a.id !== 'claudeAccount2')), false);
});
