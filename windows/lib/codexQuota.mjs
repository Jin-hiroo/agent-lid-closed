// Port of Sources/LidCore/CodexQuota.swift. Reads only typed `event_msg` metadata from a Codex
// session's local event log: rate-limit windows and quota error codes. No conversation content
// or credentials are kept. The format is not a stable API: unknown records are ignored.
import fs from 'node:fs';
import path from 'node:path';
import { blockingReset, client } from './sessions.mjs';
import { timestamp } from './t3.mjs';

const MAXIMUM_READ = 1024 * 1024;
const QUOTA_ERRORS = new Set(['usage_limit_exceeded', 'usageLimitExceeded', 'rate_limit_exceeded', 'rateLimitExceeded']);

function usageOf(limits) {
  const window = (w) => (w && typeof w.used_percent === 'number' && typeof w.resets_at === 'number'
    ? { used_percentage: w.used_percent, resets_at: w.resets_at } : undefined);
  const usage = {};
  const primary = window(limits?.primary);
  const secondary = window(limits?.secondary);
  if (primary) usage.primary = primary;
  if (secondary) usage.secondary = secondary;
  return usage;
}

export async function refreshCodexQuota(store, now, isAlive) {
  for (const record of store.loadAll().records) {
    if (client(record) !== 'codex' || !(record.pid > 0) || !isAlive(record.pid, record.pidStart)) continue;
    try {
      // The time is taken inside the lock: an older one could skip fresh events for good.
      await store.withLock(() => readOne(store, record.sessionID, Math.max(now, Date.now() / 1000)));
    } catch { /* the next refresh retries */ }
  }
}

function readOne(store, sessionID, now) {
  const current = store.load(sessionID);
  const file = current?.transcriptPath;
  if (!current || client(current) !== 'codex' || !file || !path.isAbsolute(file) || !file.endsWith('.jsonl')) return;
  let stat;
  try { stat = fs.statSync(file, { bigint: true }); } catch { return; }
  if (!stat.isFile()) return;
  const fileID = String(stat.ino);
  const size = Number(stat.size);
  const previous = current.codexTranscriptFileID === fileID ? current.codexTranscriptOffset : null;
  const offset = previous != null && previous <= size ? previous : 0;
  if (offset >= size) return;
  // Bound initial scans and bursts. Oversized lines carry no quota metadata.
  const start = Math.max(offset, size > MAXIMUM_READ ? size - MAXIMUM_READ : 0);
  const length = Math.min(MAXIMUM_READ, size - start);
  const buffer = Buffer.alloc(length);
  const fd = fs.openSync(file, 'r');
  try { fs.readSync(fd, buffer, 0, length, start); } finally { fs.closeSync(fd); }
  const lastNewline = buffer.lastIndexOf(10);
  if (lastNewline < 0) {
    if (length === MAXIMUM_READ) {
      current.codexTranscriptOffset = start + length;
      current.codexTranscriptFileID = fileID;
      store.save(current);
    }
    return;
  }
  const lines = buffer.subarray(0, lastNewline + 1).toString('utf8').split('\n').filter((l) => l.length);
  if (start > offset && lines.length) lines.shift();
  let streamTurnID = current.turnID;
  for (const line of lines) {
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    if (event?.type !== 'event_msg' || typeof event.payload?.type !== 'string') continue;
    const time = timestamp(event.timestamp);
    if (time == null || time > now + 5) continue;
    const payload = event.payload;
    const turnID = typeof payload.turn_id === 'string' ? payload.turn_id : null;
    if (payload.type === 'task_started') streamTurnID = turnID;
    if (payload.type === 'token_count' && payload.rate_limits && typeof payload.rate_limits === 'object') {
      const usage = usageOf(payload.rate_limits);
      current.quotaUsage = usage;
      current.quotaObservedAt = time;
      if (current.quotaWaitSince != null) {
        const reset = blockingReset(usage, current.quotaWaitSince);
        if (reset != null) current.quotaResetAt = reset;
      }
      continue;
    }
    const eventTurnID = turnID ?? streamTurnID;
    if (payload.type === 'task_started' && time >= current.updatedAt - 0.01) {
      current.turnID = turnID;
      current.state = 'working';
      current.reason = 'working';
      current.notified = false;
      current.stateSince = time;
      current.updatedAt = Math.max(time, current.updatedAt);
    }
    // A stale failure must not overwrite a newer prompt, approval or interrupt.
    if (current.turnID != null && eventTurnID != null && current.turnID !== eventTurnID) continue;
    const sameFinishedTurn = eventTurnID != null && eventTurnID === current.turnID
      && current.state === 'waiting' && current.reason === 'finished';
    if (!(time >= current.updatedAt - 0.01 || (payload.type === 'error' && sameFinishedTurn))) continue;
    if (payload.type === 'error') {
      const willRetry = payload.will_retry ?? payload.willRetry;
      if (willRetry === true) continue;
      const quota = QUOTA_ERRORS.has(payload.codex_error_info);
      current.state = 'waiting';
      current.reason = quota ? 'usage limit' : 'API error';
      current.notified = true;
      current.stateSince = time;
      current.updatedAt = Math.max(time, current.updatedAt);
      current.quotaWaitSince = quota ? time : null;
      current.quotaResetAt = null;
      const observed = current.quotaObservedAt;
      if (quota && observed != null && time - observed >= -1 && time - observed < 600) {
        current.quotaResetAt = blockingReset(current.quotaUsage, time);
      }
    } else if (payload.type === 'task_started' || payload.type === 'turn_aborted') {
      current.quotaWaitSince = null;
      current.quotaResetAt = null;
      if (payload.type === 'turn_aborted') {
        current.state = 'waiting';
        current.reason = 'interrupted';
        current.notified = true;
        current.stateSince = time;
        current.updatedAt = Math.max(time, current.updatedAt);
      }
    }
  }
  current.codexTranscriptOffset = start + lastNewline + 1;
  current.codexTranscriptFileID = fileID;
  store.save(current);
}
