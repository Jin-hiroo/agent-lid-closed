// Port of Sources/LidCore/Evaluator.swift, Settings.swift, QuotaWakePlan (Quota.swift) and ManualAwake.swift.
import path from 'node:path';
import { client, displayName, fileKey, shortSessionID } from './sessions.mjs';

/** Tunables, from the app settings file (same keys as the macOS defaults). */
export function lidSettings(stored = {}) {
  const value = (key) => {
    const v = Number(stored[key]);
    return stored[key] != null && Number.isFinite(v) ? Math.min(Math.max(0, v), 1_000_000) : null;
  };
  return {
    workingStale: (value('workingStaleMinutes') ?? 30) * 60,
    backgroundStale: (value('backgroundStaleMinutes') ?? 60) * 60,
    notifyTimeout: value('notifyTimeoutSeconds') ?? 90,
    sleepGrace: value('sleepGraceSeconds') ?? 10,
    batteryFloor: Math.trunc(Math.min(value('batteryFloorPercent') ?? 15, 100)),
  };
}

/** A "working" Claude session this quiet gets its transcript checked for an Esc interrupt. */
const INTERRUPT_CHECK_DELAY = 20;
/** Subagent markers without a session record are deleted after this long. */
const ORPHAN_GRACE = 60;

export function activityLabel(activity) {
  switch (activity.kind) {
    case 'working': return '作業中';
    case 'subagents': return `サブエージェント ${activity.count} 件が実行中`;
    case 'background': return 'バックグラウンドタスク実行中';
    case 'waiting': return activity.reason === 'usage limit' ? '使用量のリセット待ち' : `あなたを待っています（${reasonLabel(activity.reason)}）`;
    case 'interrupted': return '中断';
    default: return '動きがないため無視';
  }
}

const REASONS = {
  finished: '完了', question: '質問', 'plan approval': 'プランの承認', permission: '許可', 'MCP input': 'MCP の入力',
  'new session': '新しいセッション', interrupted: '中断', 'API error': 'API エラー', 'usage resume cancelled': '自動再開の取り消し',
  'T3 input request': 'T3 の入力待ち', cancelled: 'キャンセル', idle: '待機',
};
export const reasonLabel = (reason) => REASONS[reason] ?? reason;

function projectName(record) {
  if (record.cwd) {
    const base = path.win32.basename(record.cwd.replace(/[\\/]+$/, ''));
    if (base) return base;
  }
  return shortSessionID(record.sessionID);
}

export function snapshotOf(record, agentActivity, interrupted, now, settings) {
  let activity;
  let keepsAwake = false;
  let sleepAllowedAt = now;
  let since = record.stateSince;
  const stale = (limit) => now - record.updatedAt > limit;
  if (record.state === 'working' && interrupted) {
    activity = { kind: 'interrupted' };
    sleepAllowedAt = record.updatedAt + settings.sleepGrace;
  } else if (record.state === 'working' && stale(settings.workingStale)) {
    activity = { kind: 'stale' };
    since = record.updatedAt;
  } else if (record.state === 'working') {
    activity = { kind: 'working' };
    keepsAwake = true;
  } else if (record.state === 'background' && stale(settings.backgroundStale)) {
    activity = { kind: 'stale' };
    since = record.updatedAt;
  } else if (record.state === 'background') {
    activity = { kind: 'background' };
    keepsAwake = true;
  } else {
    activity = { kind: 'waiting', reason: record.reason };
    sleepAllowedAt = record.notified
      ? record.updatedAt + settings.sleepGrace
      : record.stateSince + Math.max(settings.notifyTimeout, settings.sleepGrace);
  }
  const runningAgents = agentActivity.filter((t) => now - t < settings.workingStale).length;
  if (!keepsAwake && runningAgents > 0) {
    activity = { kind: 'subagents', count: runningAgents };
    keepsAwake = true;
  }
  return {
    id: record.sessionID, project: projectName(record), provider: client(record), accountName: displayName(record),
    activity, label: activityLabel(activity), since, keepsAwake, sleepAllowedAt,
  };
}

/** Decides whether any agent session needs the computer awake. */
export function evaluate(contents, now, settings, isAlive, isInterrupted) {
  const result = { sessions: [], deadSessionIDs: [], orphanSessionKeys: [], keepAwake: false, sleepAllowedAt: 0 };
  const known = new Set();
  for (const record of contents.records) {
    const key = fileKey(record.sessionID);
    known.add(key);
    if (record.pid > 0 && !isAlive(record.pid, record.pidStart)) {
      result.deadSessionIDs.push(record.sessionID);
      continue;
    }
    const interrupted = client(record) === 'claude' && record.state === 'working'
      && now - record.updatedAt >= INTERRUPT_CHECK_DELAY && record.transcriptPath != null && isInterrupted(record.transcriptPath);
    result.sessions.push(snapshotOf(record, contents.agentActivity[key] ?? [], interrupted, now, settings));
  }
  for (const [key, times] of Object.entries(contents.agentActivity)) {
    if (!known.has(key) && now - Math.max(0, ...times) > ORPHAN_GRACE) result.orphanSessionKeys.push(key);
  }
  result.sessions.sort((a, b) => (a.keepsAwake === b.keepsAwake ? b.since - a.since : a.keepsAwake ? -1 : 1));
  result.keepAwake = result.sessions.some((s) => s.keepsAwake);
  const allowed = result.sessions.filter((s) => !s.keepsAwake).map((s) => s.sleepAllowedAt);
  result.sleepAllowedAt = allowed.length ? Math.max(...allowed) : now;
  return result;
}

// ---------------------------------------------------------------- quota wake

export const LEAD_TIME = 120;
export const RESUME_GRACE = 300;
export const MAXIMUM_WAIT = 24 * 60 * 60;
/** T3 persists its recovery across multi-day weekly limits. */
export const MAXIMUM_SCHEDULED_WAIT = 7 * 24 * 60 * 60;

/** A short hold surrounding the reset gives the agent time to continue and report real activity. */
export function quotaWakePlan(records, now, isAlive) {
  const plan = { nextWakeAt: null, nextResetAt: null, nextResetProvider: null, nextResetAccountName: null,
    holdUntil: null, holdingAccountNames: [] };
  for (const record of records) {
    const since = record.quotaWaitSince;
    const reset = record.quotaResetAt;
    if (record.state !== 'waiting' || record.reason !== 'usage limit' || !(record.pid > 0)
      || !isAlive(record.pid, record.pidStart) || !Number.isFinite(since) || !Number.isFinite(reset) || reset <= since
      || reset - since > (record.sessionID.startsWith('t3:') ? MAXIMUM_SCHEDULED_WAIT : MAXIMUM_WAIT)
      || now >= reset + RESUME_GRACE) continue;
    const account = record.quotaAccountName ?? displayName(record);
    const wake = Math.floor(reset - LEAD_TIME);
    if (wake > now + 5) {
      plan.nextWakeAt = Math.min(plan.nextWakeAt ?? wake, wake);
    } else {
      plan.holdUntil = Math.max(plan.holdUntil ?? 0, reset + RESUME_GRACE);
      if (!plan.holdingAccountNames.includes(account)) plan.holdingAccountNames.push(account);
    }
    if (reset < (plan.nextResetAt ?? Infinity)) {
      plan.nextResetAt = reset;
      plan.nextResetProvider = client(record);
      plan.nextResetAccountName = account;
    }
  }
  plan.holdingAccountNames.sort();
  return plan;
}

// ---------------------------------------------------------------- manual

export const MAXIMUM_MANUAL = 7 * 24 * 3600;

/** Parses a typed duration: `90` (minutes), `1:30`, `2h`, `45m`, `1h30m`, `1.5h`, `2 hours 10 min`. */
export function parseDuration(text) {
  const input = String(text ?? '').trim().toLowerCase();
  if (!input) return null;
  let seconds;
  if (/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/.test(input)) {
    seconds = Number(input) * 60;
  } else if (input.includes(':')) {
    const parts = input.split(':');
    if (parts.length !== 2 || !/^\d+$/.test(parts[0]) || !/^\d\d$/.test(parts[1]) || Number(parts[1]) >= 60) return null;
    seconds = Number(parts[0]) * 3600 + Number(parts[1]) * 60;
  } else {
    if (!/^(\s*[\d.]+\s*[a-z]+)+\s*$/.test(input)) return null;
    seconds = 0;
    for (const [, number, unit] of input.matchAll(/([\d.]+)\s*([a-z]+)/g)) {
      const value = Number(number);
      if (!Number.isFinite(value)) return null;
      if (['h', 'hr', 'hrs', 'hour', 'hours'].includes(unit)) seconds += value * 3600;
      else if (['m', 'min', 'mins', 'minute', 'minutes'].includes(unit)) seconds += value * 60;
      else if (['s', 'sec', 'secs', 'second', 'seconds'].includes(unit)) seconds += value;
      else return null;
    }
  }
  if (!Number.isFinite(seconds) || seconds < 1 || seconds > MAXIMUM_MANUAL) return null;
  return Math.round(seconds);
}

/** "1 時間 30 分", "45 分", "20 秒". */
export function describeDuration(duration) {
  const total = Math.max(0, Math.ceil(duration));
  if (total < 60) return `${total} 秒`;
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const parts = [];
  if (days) parts.push(`${days} 日`);
  if (hours) parts.push(`${hours} 時間`);
  if (minutes || !parts.length) parts.push(`${minutes} 分`);
  return parts.join(' ');
}
