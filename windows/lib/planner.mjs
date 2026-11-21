// Port of Sources/LidCore/AccountSwitch.swift: moves a T3 conversation blocked by one
// account's usage limit to another account of the same tool and continues it there,
// as T3's Resume button does after a manual account change.

/** A failure this recent is switched before T3's recovery worker arms it. */
export const FRESH_FAILURE_WINDOW = 15 * 60;
/** A reset estimate can be slightly early; T3 itself resumes exactly at it. */
export const RESET_MARGIN = 60;

export const PROVIDER_NAMES = { claudeAgent: 'Claude', codex: 'Codex' };

export function commandID(threadID, runID) {
  return `agent-lid-account-switch:${threadID}:${runID}`;
}

export function isEnabledInProject(account, projectID) {
  const override = projectID != null ? account.projectEnabled?.[projectID] : undefined;
  return typeof override === 'boolean' ? override : account.enabled !== false;
}

/** T3 has two configured, enabled accounts of the same tool. */
export function canSwitch(accounts) {
  const counts = {};
  for (const account of accounts) {
    if (account.configured && account.enabled !== false) counts[account.driver] = (counts[account.driver] ?? 0) + 1;
  }
  return Object.values(counts).some((n) => n > 1);
}

function modelOf(selection) {
  try {
    const parsed = JSON.parse(selection);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) && typeof parsed.model === 'string'
      ? parsed.model : null;
  } catch {
    return null;
  }
}

/** JSON with sorted keys, so the same switch always serializes identically. */
export function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/** The same `message.dispatch` T3's Resume button sends with another account selected. */
export function buildCommand(thread, source, target) {
  let selection;
  try {
    selection = JSON.parse(thread.modelSelection);
  } catch {
    return null;
  }
  if (!selection || typeof selection !== 'object' || Array.isArray(selection) || typeof selection.model !== 'string') {
    return null;
  }
  selection.instanceId = target.id;
  const id = commandID(thread.threadID, thread.runID);
  return stableStringify({
    type: 'message.dispatch',
    commandId: id,
    messageId: id,
    threadId: thread.threadID,
    createdBy: 'user',
    creationSource: 'server',
    manualContinuationOfRunId: thread.runID,
    modelSelection: selection,
    text: `Continue where you left off. ${source.name} reached its usage limit, `
      + `so Agent Lid Closed moved this conversation to ${target.name}.`,
    attachments: [],
    dispatchMode: { type: 'start_immediately' },
  });
}

function projectName(thread) {
  if (thread.cwd) {
    const parts = thread.cwd.split(/[\\/]+/).filter(Boolean);
    if (parts.length) return parts[parts.length - 1];
  }
  return thread.threadID.slice(0, 8);
}

/**
 * `limitedUntil` maps an account to its latest known reset (unix seconds).
 * T3's global opt-out of automatic continuation also turns switching off.
 */
export function plan({ threads, accounts, limitedUntil, now, continuationDisabled = false }) {
  const result = { switches: [], earlierResets: {} };
  if (continuationDisabled) return result;
  const byID = new Map();
  for (const account of accounts) if (!byID.has(account.id)) byID.set(account.id, account);
  const availableAt = (account) => (limitedUntil[account.id] != null ? limitedUntil[account.id] + RESET_MARGIN : 0);

  for (const thread of threads) {
    if (thread.isDelegated || thread.autoResume === false) continue;
    if ((thread.snoozedUntil ?? 0) > now) continue;
    const fresh = now >= thread.failedAt && now - thread.failedAt < FRESH_FAILURE_WINDOW;
    if (!(thread.autoResume === true || fresh)) continue;
    const source = byID.get(thread.accountID);
    const model = modelOf(thread.modelSelection);
    if (!source || !model) continue;
    const sourceCustom = source.customModels ?? [];
    const candidates = accounts.filter((account) =>
      account.id !== source.id && account.driver === source.driver && account.configured
      && isEnabledInProject(account, thread.projectID)
      && (!sourceCustom.includes(model) || (account.customModels ?? []).includes(model)))
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

    const target = candidates.find((account) => availableAt(account) <= now);
    if (target) {
      const command = buildCommand(thread, source, target);
      if (!command) continue;
      result.switches.push({
        threadID: thread.threadID,
        runID: thread.runID,
        commandID: commandID(thread.threadID, thread.runID),
        project: projectName(thread),
        from: source,
        to: target,
        command,
      });
    } else if (candidates.length) {
      const next = candidates.reduce((best, account) => (availableAt(account) < availableAt(best) ? account : best));
      if (availableAt(next) < Math.max(thread.resetAt, thread.snoozedUntil ?? 0)) {
        result.earlierResets[thread.threadID] = { at: availableAt(next), accountName: next.name };
      }
    }
  }
  return result;
}

/** Two planned switches are the same when they would send the same command to the same account. */
export function sameSwitch(a, b) {
  return a.commandID === b.commandID && a.from.id === b.from.id && a.to.id === b.to.id && a.command === b.command;
}
