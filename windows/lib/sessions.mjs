// Port of Sources/LidCore/SessionStore.swift, HookLogic.swift and the status-line part of Quota.swift.
// Session files use the same JSON fields as the macOS app.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { stateDirectory } from './settings.mjs';

export const PROVIDER_NAME = { claude: 'Claude', codex: 'Codex' };

export function sessionsDirectory() {
  return path.join(stateDirectory(), 'sessions');
}

export function sessionKey(provider, id) {
  return provider === 'codex' ? `codex:${id}` : id;
}

export function shortSessionID(key) {
  return (key.startsWith('codex:') ? key.slice(6) : key).slice(0, 8);
}

const AGENT_SEPARATOR = '.agent.';

/** `id` reduced to characters that are safe in a file name. */
export function fileKey(id) {
  return [...String(id)].map((c) => (/[A-Za-z0-9_-]/.test(c) ? c : '_')).join('').slice(0, 128);
}

export function client(record) {
  return record.provider ?? 'claude';
}

export function displayName(record) {
  return record.accountName ?? PROVIDER_NAME[client(record)];
}

// ---------------------------------------------------------------- quota

/** Both exhausted windows must reset before work can resume. */
export function blockingReset(usage, after) {
  if (!usage) return null;
  const resets = ['five_hour', 'seven_day', 'primary', 'secondary'].map((k) => usage[k]).filter((w) =>
    w && Number.isFinite(w.used_percentage) && w.used_percentage >= 100 && Number.isFinite(w.resets_at) && w.resets_at > after)
    .map((w) => w.resets_at);
  return resets.length ? Math.max(...resets) : null;
}

function window(value) {
  if (!value || typeof value !== 'object') return undefined;
  const used = value.used_percentage;
  const reset = value.resets_at;
  if (typeof used !== 'number' || typeof reset !== 'number') return undefined;
  return { used_percentage: used, resets_at: reset };
}

/** Claude's documented status-line `rate_limits`, or null. */
export function parseUsage(value) {
  if (!value || typeof value !== 'object') return null;
  const usage = {};
  for (const key of ['five_hour', 'seven_day', 'primary', 'secondary']) {
    const w = window(value[key]);
    if (w) usage[key] = w;
  }
  return usage;
}

const sameJSON = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

// ---------------------------------------------------------------- store

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

export class SessionStore {
  constructor(dir = sessionsDirectory()) {
    this.dir = dir;
  }

  recordPath(sessionID) {
    return path.join(this.dir, `${fileKey(sessionID)}.json`);
  }

  agentPath(sessionID, agentID) {
    return path.join(this.dir, `${fileKey(sessionID)}${AGENT_SEPARATOR}${fileKey(agentID)}`);
  }

  load(sessionID) {
    try {
      return JSON.parse(fs.readFileSync(this.recordPath(sessionID), 'utf8'));
    } catch {
      return null;
    }
  }

  /** Writes atomically (temp file + rename), so readers never see a partial record. */
  save(record) {
    fs.mkdirSync(this.dir, { recursive: true });
    const temporary = path.join(this.dir, `.${fileKey(record.sessionID)}.${process.pid}.tmp`);
    fs.writeFileSync(temporary, JSON.stringify(record));
    for (let attempt = 0; ; attempt += 1) {
      try {
        fs.renameSync(temporary, this.recordPath(record.sessionID));
        return;
      } catch (error) {
        // Windows refuses to replace a file another process has open for a moment.
        if (attempt >= 20 || !['EPERM', 'EBUSY', 'EACCES'].includes(error.code)) {
          try { fs.unlinkSync(temporary); } catch { /* ignore */ }
          throw error;
        }
        sleepSync(10);
      }
    }
  }

  /** Removes the session record and its subagent markers. */
  remove(sessionID) {
    const key = fileKey(sessionID);
    let names = [];
    try { names = fs.readdirSync(this.dir); } catch { return; }
    for (const name of names) {
      if (name === `${key}.json` || name.startsWith(key + AGENT_SEPARATOR)) {
        try { fs.unlinkSync(path.join(this.dir, name)); } catch { /* ignore */ }
      }
    }
  }

  touchAgent(sessionID, agentID) {
    fs.mkdirSync(this.dir, { recursive: true });
    const file = this.agentPath(sessionID, agentID);
    const now = new Date();
    try {
      fs.utimesSync(file, now, now);
    } catch {
      fs.writeFileSync(file, '');
    }
  }

  removeAgent(sessionID, agentID) {
    try { fs.unlinkSync(this.agentPath(sessionID, agentID)); } catch { /* ignore */ }
  }

  loadAll() {
    const contents = { records: [], agentActivity: {} };
    let names = [];
    try { names = fs.readdirSync(this.dir); } catch { return contents; }
    for (const name of names) {
      if (name.startsWith('.')) continue;
      const file = path.join(this.dir, name);
      if (name.endsWith('.json')) {
        try {
          const record = JSON.parse(fs.readFileSync(file, 'utf8'));
          if (record && typeof record.sessionID === 'string') contents.records.push(record);
        } catch { /* partial or foreign file */ }
      } else {
        const index = name.indexOf(AGENT_SEPARATOR);
        if (index < 0) continue;
        let modified = 0;
        try { modified = fs.statSync(file).mtimeMs / 1000; } catch { /* removed meanwhile */ }
        (contents.agentActivity[name.slice(0, index)] ??= []).push(modified);
      }
    }
    return contents;
  }

  /**
   * Serializes read-modify-write between hooks that run at the same time (parallel tool calls),
   * like flock on macOS. On Windows the lock is a named pipe: only one process can create it, and
   * Windows removes it when that process exits, crash included, so there is no stale lock to break.
   * Without the lock within about 3 s, the body doesn't run and this throws, rather than writing
   * unlocked.
   */
  async withLock(body) {
    fs.mkdirSync(this.dir, { recursive: true });
    const server = await acquireLock(this.dir);
    try {
      return await body();
    } finally {
      await new Promise((resolve) => server.close(() => resolve()));
    }
  }

  /** Removes a session only if, under the lock, it's still the record that was judged gone. */
  async removeIfUnchanged(record) {
    await this.withLock(() => {
      const current = this.load(record.sessionID);
      if (!current || (current.pid === record.pid && current.updatedAt === record.updatedAt)) this.remove(record.sessionID);
    });
  }

  /** Removes subagent markers left without a session, if, under the lock, that's still the case. */
  async removeOrphan(key, grace, now) {
    await this.withLock(() => {
      if (fs.existsSync(path.join(this.dir, `${key}.json`))) return;
      const times = this.loadAll().agentActivity[key] ?? [];
      if (times.length && now - Math.max(...times) > grace) this.remove(key);
    });
  }
}

function lockName(dir) {
  const hash = createHash('sha256').update(path.resolve(dir).toLowerCase()).digest('hex').slice(0, 24);
  return process.platform === 'win32' ? String.raw`\\.\pipe\agent-lid-closed-` + hash
    : path.join(os.tmpdir(), `agent-lid-closed-${hash}.sock`);
}

async function acquireLock(dir) {
  const name = lockName(dir);
  const deadline = Date.now() + 3000;
  for (;;) {
    try {
      return await new Promise((resolve, reject) => {
        const server = net.createServer();
        server.once('error', reject);
        server.listen(name, () => resolve(server));
      });
    } catch (error) {
      if (error.code !== 'EADDRINUSE' || Date.now() > deadline) throw new Error('session store is busy');
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
}

// ---------------------------------------------------------------- hooks

/** Shared Claude Code / Codex hook fields. Lenient: a field with an unexpected type is treated as missing. */
export function parseHookInput(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const s = (v) => (typeof v === 'string' ? v : null);
  const event = s(raw.hook_event_name);
  const sessionID = s(raw.session_id);
  if (!event || !sessionID) return null;
  return {
    event, sessionID,
    agentID: s(raw.agent_id),
    toolName: s(raw.tool_name),
    notificationType: s(raw.notification_type),
    source: s(raw.source),
    error: s(raw.error),
    turnID: s(raw.turn_id),
    cwd: s(raw.cwd),
    transcriptPath: s(raw.transcript_path),
    backgroundTaskStatuses: Array.isArray(raw.background_tasks)
      ? raw.background_tasks.map((t) => (t && typeof t.status === 'string' ? t.status : '')) : null,
  };
}

const USER_INPUT_TOOLS = { AskUserQuestion: 'question', ExitPlanMode: 'plan approval' };
const WAITING_NOTIFICATIONS = {
  permission_prompt: 'permission', elicitation_dialog: 'MCP input', elicitation_url_dialog: 'MCP input',
};
const FINISHED_TASK_STATUSES = new Set(['completed', 'complete', 'done', 'finished', 'succeeded', 'success',
  'failed', 'error', 'killed', 'stopped', 'cancelled', 'canceled', 'timeout', 'timed_out']);

const set = (state, reason, notified) => ({ kind: 'set', state, reason, notified });

export function hookAction(input, provider = 'claude') {
  if (input.event === 'SessionEnd') return { kind: 'endSession' };
  if (input.agentID) {
    // Inside a subagent: track it separately so it can't overwrite the main agent's state.
    return input.event === 'SubagentStop' ? { kind: 'subagentDone', agent: input.agentID } : { kind: 'subagentActive', agent: input.agentID };
  }
  switch (input.event) {
    case 'SessionStart':
      return input.source === 'compact' ? { kind: 'keepState' } : set('waiting', 'new session', true);
    case 'UserPromptSubmit': case 'PostToolUse': case 'PostToolUseFailure': case 'ElicitationResult':
      return set('working', 'working', false);
    case 'PreToolUse':
      if (provider === 'codex' && input.toolName?.split('.').pop() === 'request_user_input') return set('waiting', 'question', true);
      if (USER_INPUT_TOOLS[input.toolName ?? '']) return set('waiting', USER_INPUT_TOOLS[input.toolName], false);
      return set('working', 'working', false);
    case 'PermissionRequest':
      return provider === 'codex' ? set('working', 'working', false) : { kind: 'ignore' };
    case 'Interrupt':
      return provider === 'codex' ? set('waiting', 'interrupted', true) : { kind: 'ignore' };
    case 'PreCompact': case 'PostCompact':
      return provider === 'codex' ? { kind: 'keepState' } : { kind: 'ignore' };
    case 'Notification': {
      const type = input.notificationType ?? '';
      if (type === 'quota_auto_resume_fired') return set('working', 'working', false);
      if (type === 'quota_auto_resume_stale' || type === 'quota_auto_resume_disabled') return set('waiting', 'usage resume cancelled', true);
      if (type === 'idle_prompt') return set('waiting', null, true);
      if (WAITING_NOTIFICATIONS[type]) return set('waiting', WAITING_NOTIFICATIONS[type], true);
      return { kind: 'ignore' };
    }
    case 'Elicitation':
      return set('waiting', 'MCP input', false);
    case 'Stop': {
      const running = (input.backgroundTaskStatuses ?? []).some((s) => !FINISHED_TASK_STATUSES.has(s.toLowerCase()));
      return running ? set('background', 'background tasks', false) : set('waiting', 'finished', provider === 'codex');
    }
    case 'StopFailure':
      if (provider === 'claude' && input.error === 'rate_limit') return set('waiting', 'usage limit', true);
      return set('waiting', 'API error', false);
    default:
      return { kind: 'ignore' };
  }
}

/** Applies `action` to the stored session. `owner` is the process that ran the hook, or null to keep the known one. */
export function applyHook(action, input, owner, store, now, provider = 'claude') {
  const existing = store.load(input.sessionID);
  if (provider === 'codex' && !input.agentID && existing?.turnID && input.turnID && existing.turnID !== input.turnID
    && !['UserPromptSubmit', 'SessionStart', 'SessionEnd'].includes(input.event)) {
    // A delayed tool/Stop hook from an interrupted turn cannot replace its successor.
    return;
  }
  const fresh = (state, reason) => ({ sessionID: input.sessionID, state, reason, notified: false,
    stateSince: now, updatedAt: now, pid: 0, pidStart: 0 });
  let record;
  switch (action.kind) {
    case 'ignore':
      return;
    case 'endSession':
      store.remove(input.sessionID);
      return;
    case 'subagentDone':
      store.removeAgent(input.sessionID, action.agent);
      return;
    case 'subagentActive':
      store.touchAgent(input.sessionID, action.agent);
      // The session record carries the PID used to clean up after a crash, so make sure it exists.
      if (existing) return;
      record = fresh('working', 'working');
      break;
    case 'keepState':
      record = existing ? { ...existing } : fresh('working', 'working');
      break;
    case 'set':
      if (existing && existing.state === action.state) {
        record = { ...existing, notified: existing.notified || action.notified };
        if (action.reason != null) record.reason = action.reason;
      } else {
        record = fresh(action.state, action.reason ?? 'idle');
        record.notified = action.notified;
        if (existing) {
          record.pid = existing.pid;
          record.pidStart = existing.pidStart;
          if (existing.cwd != null) record.cwd = existing.cwd;
          if (existing.transcriptPath != null) record.transcriptPath = existing.transcriptPath;
        }
      }
      break;
    default:
      return;
  }
  record.updatedAt = now;
  // The status-line callback can arrive before or after StopFailure. Preserve its cached
  // limits across state changes; only a real quota failure arms a wake.
  record.quotaUsage = existing?.quotaUsage;
  record.quotaObservedAt = existing?.quotaObservedAt;
  record.turnID = input.turnID ?? existing?.turnID;
  record.codexTranscriptOffset = existing?.codexTranscriptOffset;
  record.codexTranscriptFileID = existing?.codexTranscriptFileID;
  if (input.event === 'StopFailure' && input.error === 'rate_limit' && provider === 'claude') {
    record.quotaWaitSince = now;
    record.quotaResetAt = null;
    const observed = record.quotaObservedAt;
    if (observed != null && now - observed >= 0 && now - observed < 600) {
      record.quotaResetAt = blockingReset(record.quotaUsage, now);
    }
  } else if (provider === 'codex' && input.event === 'Stop' && existing?.reason === 'usage limit' && existing?.quotaWaitSince != null) {
    // Stop bookkeeping can race the local error reader in either order.
    record.reason = 'usage limit';
    record.quotaWaitSince = existing.quotaWaitSince;
    record.quotaResetAt = existing.quotaResetAt;
  } else if (action.kind === 'set' && action.reason != null) {
    record.quotaWaitSince = null;
    record.quotaResetAt = null;
  } else {
    record.quotaWaitSince = existing?.quotaWaitSince;
    record.quotaResetAt = existing?.quotaResetAt;
  }
  record.provider = provider;
  if (owner) {
    record.pid = owner.pid;
    record.pidStart = owner.startTime;
  }
  if (input.cwd) record.cwd = input.cwd;
  if (input.transcriptPath) record.transcriptPath = input.transcriptPath;
  store.save(record);
}

/** Status-line updates preserve the activity heartbeat and the owner discovered by the hooks. */
export async function saveStatusLine(raw, store, now) {
  if (!raw || typeof raw.session_id !== 'string') return;
  const usage = raw.rate_limits === undefined ? null : parseUsage(raw.rate_limits);
  await store.withLock(() => {
    const record = store.load(raw.session_id);
    if (!record || client(record) !== 'claude') return;
    const reset = record.quotaWaitSince != null ? blockingReset(usage, record.quotaWaitSince) : null;
    // Streaming status refreshes can arrive several times per second.
    if (sameJSON(record.quotaUsage, usage) && (reset == null || reset === record.quotaResetAt)
      && record.quotaObservedAt != null && now >= record.quotaObservedAt && now - record.quotaObservedAt < 30) return;
    record.quotaUsage = usage;
    record.quotaObservedAt = now;
    if (reset != null) record.quotaResetAt = reset;
    store.save(record);
  });
}
