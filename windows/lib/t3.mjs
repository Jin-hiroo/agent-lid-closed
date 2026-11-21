// Port of Sources/LidCore/T3Monitor.swift. Reads T3's durable orchestration metadata through a
// read-only SQLite connection. T3 owns continuation, including deduplication, cancellation and the
// original conversation's permissions. No credentials, prompts, or conversation bodies are read.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { DatabaseSync, StatementSync } from 'node:sqlite';
import { PROVIDER_NAMES, RESET_MARGIN } from './planner.mjs';
import { fileKey } from './sessions.mjs';

export function defaultT3Directory() {
  if (process.env.AGENT_LID_T3_DIR) return process.env.AGENT_LID_T3_DIR;
  // Isolated test runs must never read or change the user's live T3 Code (as on macOS).
  if (process.env.AGENT_LID_STATE_DIR) return path.join(process.env.AGENT_LID_STATE_DIR, 't3-disabled');
  return path.join(os.homedir(), '.t3', 'userdata');
}

export function timestamp(value) {
  if (value == null) return null;
  const ms = Date.parse(String(value));
  return Number.isFinite(ms) ? ms / 1000 : null;
}

const str = (v) => (v == null ? null : String(v));

function readJSON(file) {
  try {
    let text = fs.readFileSync(file, 'utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

/** Windows process creation time in unix seconds, or null. Used only without the helper. */
function processStartTime(pid) {
  const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    `(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')`],
  { encoding: 'utf8', windowsHide: true, timeout: 15_000 });
  return result.status === 0 ? timestamp(result.stdout.trim()) : null;
}

const verifiedRuntimes = new Map();

/** The live T3 server, from its runtime file, or null when T3 isn't running. As on macOS, the
 *  runtime's start time must match the process, so a reused PID can't pass for T3.
 *  `processes` (lib/process.mjs) supplies start times; without it PowerShell is asked once. */
export function serverRuntime(directory = defaultT3Directory(), processes = null) {
  const runtime = readJSON(path.join(directory, 'server-runtime.json'));
  if (!runtime || !Number.isInteger(runtime.pid) || runtime.pid <= 1) return null;
  if (!Number.isInteger(runtime.port) || runtime.port < 1 || runtime.port > 65535) return null;
  const started = timestamp(runtime.startedAt);
  if (started == null) return null;
  let ownerStart;
  const identity = processes?.map ? processes.identity(runtime.pid) : undefined;
  if (identity !== undefined) {
    if (!identity) return null;
    ownerStart = identity.startTime;
  } else {
    if (!isAlive(runtime.pid)) return null;
    const key = `${runtime.pid}|${runtime.startedAt}`;
    if (!verifiedRuntimes.has(key)) {
      const start = processStartTime(runtime.pid);
      // A failed lookup is retried on the next read instead of being cached.
      if (start == null) return null;
      verifiedRuntimes.clear();
      verifiedRuntimes.set(key, start);
    }
    ownerStart = verifiedRuntimes.get(key);
  }
  if (!(started >= ownerStart - 1 && started - ownerStart < 120)) return null;
  return { ...runtime, owner: { pid: runtime.pid, startTime: ownerStart } };
}

const bool = (v) => (typeof v === 'boolean' ? v : null);

/** Parses T3's settings. Every field is optional so one unusual instance can't hide the others. */
export function parseSettings(raw) {
  const settings = { providerInstances: {}, projectEnabled: {}, autoResumeLimitedThreads: null };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return settings;
  const instances = raw.providerInstances && typeof raw.providerInstances === 'object' ? raw.providerInstances : {};
  for (const [id, instance] of Object.entries(instances)) {
    if (!instance || typeof instance !== 'object') continue;
    const config = instance.config && typeof instance.config === 'object' ? instance.config : {};
    const models = Array.isArray(config.customModels) ? config.customModels : [];
    const envelope = bool(instance.enabled);
    const legacy = bool(config.enabled);
    settings.providerInstances[id] = {
      driver: typeof instance.driver === 'string' ? instance.driver : null,
      displayName: typeof instance.displayName === 'string' ? instance.displayName : null,
      // As T3 resolves it: a false on the envelope or the legacy config flag wins.
      enabled: envelope === false || legacy === false ? false : (envelope ?? legacy),
      customModels: models.map((m) => (typeof m === 'string' ? m : m && typeof m.slug === 'string' ? m.slug : null))
        .filter(Boolean),
    };
  }
  const overrides = raw.projectSettingsOverrides && typeof raw.projectSettingsOverrides === 'object'
    ? raw.projectSettingsOverrides : {};
  for (const [project, override] of Object.entries(overrides)) {
    const map = {};
    const provider = override && typeof override.providerInstances === 'object' ? override.providerInstances : {};
    for (const [id, entry] of Object.entries(provider ?? {})) {
      if (entry && typeof entry.enabled === 'boolean') map[id] = entry.enabled;
    }
    settings.projectEnabled[project] = map;
  }
  settings.autoResumeLimitedThreads = bool(raw.autoResumeLimitedThreads);
  return settings;
}

export function accountNames(instances) {
  const names = {};
  for (const [id, instance] of Object.entries(instances)) {
    const provider = PROVIDER_NAMES[instance.driver];
    const name = instance.displayName?.trim();
    if (!provider || !name) continue;
    names[id] = name.toLowerCase().includes(provider.toLowerCase()) ? name : `${provider} (${name})`;
  }
  return names;
}

/** T3's built-in instance for each tool is named after its driver and exists even when settings don't mention it. */
export function accountsFrom(settings) {
  const instances = settings.providerInstances;
  const names = accountNames(instances);
  const projectEnabled = (id) => {
    const map = {};
    for (const [project, overrides] of Object.entries(settings.projectEnabled)) {
      if (typeof overrides[id] === 'boolean') map[project] = overrides[id];
    }
    return map;
  };
  const accounts = [];
  for (const [id, instance] of Object.entries(instances)) {
    const provider = PROVIDER_NAMES[instance.driver];
    if (!provider) continue;
    accounts.push({
      id, driver: instance.driver, name: names[id] ?? provider, enabled: instance.enabled ?? true,
      projectEnabled: projectEnabled(id), configured: true, customModels: instance.customModels,
    });
  }
  for (const driver of Object.keys(PROVIDER_NAMES)) {
    if (instances[driver]) continue;
    accounts.push({
      id: driver, driver, name: PROVIDER_NAMES[driver], enabled: true,
      projectEnabled: projectEnabled(driver), configured: false, customModels: [],
    });
  }
  return accounts.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** T3's accounts and auto-resume choice, read from its settings even when T3 isn't running. */
export function configuration(directory = defaultT3Directory()) {
  const file = path.join(directory, 'settings.json');
  if (!fs.existsSync(file)) return null;
  const settings = parseSettings(readJSON(file));
  return { accounts: accountsFrom(settings), autoResume: settings.autoResumeLimitedThreads };
}

const PROVIDERS = { codex: 'codex', claudeAgent: 'claude' };
const nativeSessionKey = (provider, id) => (provider === 'codex' ? `codex:${id}` : id);

function emptySnapshot(config) {
  return {
    installed: config != null,
    running: false,
    owner: null,
    accounts: config?.accounts ?? [],
    accountNames: config?.accountNames ?? {},
    autoResume: config?.autoResume ?? null,
    continuationDisabled: config?.autoResume === false,
    records: [],
    ownedSessionIDs: new Set(),
    working: 0,
    limitedThreads: [],
    limitedUntil: {},
    error: null,
  };
}

/**
 * Reads T3's activity: session records for the sleep decision, the native session IDs T3 owns,
 * conversations blocked by a usage limit and each account's known reset.
 */
export function read({ directory = defaultT3Directory(), now = Date.now() / 1000, processes = null } = {}) {
  const file = path.join(directory, 'settings.json');
  let config = null;
  if (fs.existsSync(file)) {
    const settings = parseSettings(readJSON(file));
    config = { accounts: accountsFrom(settings), accountNames: accountNames(settings.providerInstances),
      autoResume: settings.autoResumeLimitedThreads };
  }
  const snapshot = emptySnapshot(config);
  const runtime = serverRuntime(directory, processes);
  if (!runtime) return snapshot;
  const owner = runtime.owner;
  snapshot.running = true;
  snapshot.owner = owner;
  if (typeof StatementSync?.prototype?.setReturnArrays !== 'function') {
    snapshot.error = 'Node.js 22.16 or later is required to read T3 Code';
    return snapshot;
  }

  let db;
  try {
    // Never create a missing DB, change its schema, or write T3 state.
    db = new DatabaseSync(path.join(directory, 'statev2.sqlite'), { readOnly: true });
  } catch {
    snapshot.error = 'T3 activity unavailable: could not open its database';
    return snapshot;
  }
  let ownershipLoaded = false;
  try {
    db.exec('PRAGMA busy_timeout = 200');
    // All metadata comes from one commit while T3 continues to write.
    db.exec('BEGIN');
    try {
      // Ownership is independent of activity. Settling, archiving, opting out, or finishing
      // must not let a T3 provider fall back to its hooks.
      const ownership = db.prepare(OWNERSHIP_SQL);
      ownership.setReturnArrays(true);
      for (const row of ownership.all()) {
        const nativeID = str(row[0]);
        const provider = PROVIDERS[str(row[1])];
        if (nativeID && provider) snapshot.ownedSessionIDs.add(nativeSessionKey(provider, nativeID));
      }
      ownershipLoaded = true;

      const activity = db.prepare(ACTIVITY_SQL);
      activity.setReturnArrays(true);
      for (const row of activity.all(now)) {
        const threadID = str(row[0]);
        const status = str(row[1]);
        const provider = PROVIDERS[str(row[2])];
        const since = timestamp(row[3]);
        if (!threadID || !status || !provider || since == null) continue;
        const pendingInput = Number(row[5]) !== 0;
        if (['preparing', 'starting', 'running'].includes(status) && !pendingInput) snapshot.working += 1;
        const record = {
          sessionID: `t3:${threadID}`, state: 'working', reason: 'T3 Code', notified: true, stateSince: since,
          updatedAt: timestamp(row[17]) ?? since, pid: owner.pid, pidStart: owner.startTime, cwd: str(row[4]), provider,
        };
        record.providerInstanceID = str(row[20]);
        if (record.providerInstanceID && snapshot.accountNames[record.providerInstanceID]) {
          record.accountName = snapshot.accountNames[record.providerInstanceID];
        }
        const backgroundActivity = timestamp(row[18]);
        if ((Number(row[15]) > 0 || backgroundActivity != null) && !['preparing', 'starting', 'running'].includes(status)) {
          snapshot.records.push({
            ...record, sessionID: `${record.sessionID}:background`, state: 'background', reason: 'T3 background tasks',
            updatedAt: Math.max(timestamp(row[16]) ?? since, backgroundActivity ?? since),
          });
        }
        if (pendingInput) {
          record.state = 'waiting';
          record.reason = 'T3 input request';
          record.stateSince = timestamp(row[14]) ?? since;
          record.updatedAt = record.stateSince;
        } else if (status === 'failed') {
          // The same conditions T3 applies before continuing a limited run: the conversation still
          // uses the failed account and no later error from that account superseded the limit.
          const reset = timestamp(row[7]);
          const runID = str(row[10]);
          const instance = str(row[20]);
          const selection = str(row[23]);
          const sessionError = str(row[21]);
          const supersededBy = sessionError != null && sessionError !== str(row[22]);
          if (str(row[6]) === 'usage_limit' && reset != null && reset > since && Number(row[12]) !== 0
            && !supersededBy && runID && instance && selection) {
            const armed = str(row[9]) === runID && row[25] != null;
            snapshot.limitedThreads.push({
              threadID, runID, projectID: str(row[26]), accountID: instance, failedAt: since, resetAt: reset,
              snoozedUntil: timestamp(row[13]),
              autoResume: armed ? Number(row[25]) !== 0 : null,
              isDelegated: str(row[24]) === 'subagent',
              modelSelection: selection, cwd: str(row[4]), record: { ...record },
            });
          }
          // Only a recovery durably armed for this exact failed run and reset can schedule a wake.
          const recoveryReset = timestamp(row[11]);
          if (!(str(row[6]) === 'usage_limit' && reset != null && reset > since && Number(row[8]) !== 0
            && str(row[9]) === runID && recoveryReset === reset && Number(row[12]) !== 0)) continue;
          if (supersededBy) continue;
          const snoozed = timestamp(row[13]) ?? 0;
          record.state = 'waiting';
          record.reason = 'usage limit';
          record.updatedAt = since;
          record.quotaWaitSince = since;
          // T3 retains the recovery when a later user snooze delays it.
          record.quotaResetAt = Math.max(reset, snoozed);
        } else if (['completed', 'cancelled', 'interrupted'].includes(status)) {
          record.state = 'waiting';
          record.reason = status === 'completed' ? 'finished' : status;
          record.updatedAt = since;
        }
        snapshot.records.push(record);
      }
      // An account stays limited until its reset, unless a run started after the failure has
      // since completed on it. Unknown limits stop switching rather than the activity reported.
      try {
        const provenAt = {};
        const proven = db.prepare(PROVEN_ACCOUNTS_SQL);
        proven.setReturnArrays(true);
        for (const row of proven.all()) {
          if (row[0] != null && row[1] != null) provenAt[String(row[0])] = Number(row[1]);
        }
        const limited = db.prepare(LIMITED_ACCOUNTS_SQL);
        limited.setReturnArrays(true);
        for (const row of limited.all(now)) {
          const instance = str(row[0]);
          const reset = timestamp(row[1]);
          const failedAt = timestamp(row[2]);
          if (!instance || reset == null || reset + RESET_MARGIN <= now || failedAt == null) continue;
          if (failedAt <= (provenAt[instance] ?? -Infinity)) continue;
          snapshot.limitedUntil[instance] = Math.max(snapshot.limitedUntil[instance] ?? reset, reset);
        }
      } catch {
        snapshot.limitedUntil = {};
        snapshot.continuationDisabled = true;
      }
    } finally {
      try { db.exec('ROLLBACK'); } catch { /* already closed */ }
    }
  } catch {
    // Discard partial activity. Independently loaded ownership remains valid, preventing settled
    // T3 work from reappearing through hooks.
    const owned = ownershipLoaded ? snapshot.ownedSessionIDs : new Set();
    const failed = emptySnapshot(config);
    failed.running = true;
    failed.owner = owner;
    failed.ownedSessionIDs = owned;
    failed.error = 'T3 activity unavailable: database busy or unsupported schema';
    return failed;
  } finally {
    try { db.close(); } catch { /* ignore */ }
  }
  return snapshot;
}

/** Conversations whose account switch is being delivered keep the computer awake; another
 *  account's earlier reset brings their wake forward. */
export function applyAccountSwitching(snapshot, delivering, earlierResets, now) {
  for (const thread of snapshot.limitedThreads) {
    const id = `t3:${thread.threadID}`;
    if (delivering.has(thread.threadID)) {
      const record = { ...thread.record, state: 'working', reason: 'switching account', stateSince: thread.failedAt, updatedAt: now };
      snapshot.records = snapshot.records.filter((r) => r.sessionID !== id);
      snapshot.records.push(record);
    } else if (earlierResets[thread.threadID]) {
      const earlier = earlierResets[thread.threadID];
      const record = snapshot.records.find((r) => r.sessionID === id && r.reason === 'usage limit');
      if (record?.quotaResetAt != null && earlier.at < record.quotaResetAt) {
        record.quotaResetAt = earlier.at;
        record.quotaAccountName = earlier.accountName;
      }
    }
  }
}

/** Native state wins over hooks from the same T3-owned conversation. In particular, a dead
 *  provider child must not erase a durable wait. */
export function mergeWithHooks(snapshot, hooks, processes) {
  const owner = snapshot.owner;
  const shadowed = new Set(hooks.records.filter((record) => {
    if (!snapshot.ownedSessionIDs.has(record.sessionID)) return false;
    return !(record.pid > 0) || !processes.isAlive(record.pid, record.pidStart)
      || (owner != null && processes.isDescendant(record.pid, owner.pid));
  }).map((r) => r.sessionID));
  const agentActivity = { ...hooks.agentActivity };
  for (const id of shadowed) delete agentActivity[fileKey(id)];
  return {
    records: [...hooks.records.filter((r) => !shadowed.has(r.sessionID)), ...snapshot.records],
    agentActivity,
  };
}

/** A transient read failure must not drop work or a reset hold. A confirmed host exit bypasses
 *  the cache, and errors cannot extend its 60 s lifetime. */
export class T3Cache {
  lastGood = null;
  lastGoodAt = -Infinity;

  resolve(current, now) {
    if (!current.error) {
      this.lastGood = current;
      this.lastGoodAt = now;
      return current;
    }
    const sameOwner = (a, b) => a && b && a.pid === b.pid && Math.abs(a.startTime - b.startTime) < 1;
    if (!this.lastGood || !sameOwner(current.owner, this.lastGood.owner)) return current;
    if (now < this.lastGoodAt || now - this.lastGoodAt >= 60) {
      // Activity expires, but known T3-owned IDs remain authoritative for this live host.
      return { ...current, ownedSessionIDs: new Set([...current.ownedSessionIDs, ...this.lastGood.ownedSessionIDs]) };
    }
    return {
      ...this.lastGood,
      records: [...this.lastGood.records],
      ownedSessionIDs: new Set([...this.lastGood.ownedSessionIDs, ...current.ownedSessionIDs]),
      error: current.error,
    };
  }
}

const BACKGROUND_ACTIVITY_SQL = `
  (SELECT MAX(work.updated_at) FROM orchestration_v2_projection_turn_items work
   LEFT JOIN orchestration_v2_projection_runs work_run ON work_run.run_id = work.run_id
   WHERE work.thread_id = t.thread_id
     AND work.type IN ('command_execution', 'dynamic_tool', 'subagent')
     AND work.status IN ('pending', 'running', 'waiting')
     AND NOT (work.type = 'dynamic_tool' AND json_extract(work.payload_json, '$.input.persistent') IS 1)
     AND work_run.status IS NOT 'rolled_back')`;

/** Usage-limit failures of any conversation, by account, whose reset is ahead or just passed. */
const LIMITED_ACCOUNTS_SQL = `
  SELECT r.provider_instance_id, json_extract(item.payload_json, '$.failure.resetAt'),
    COALESCE(r.completed_at, item.updated_at)
  FROM orchestration_v2_projection_runs r
  JOIN orchestration_v2_projection_turn_items item ON item.turn_item_id = (
    SELECT error.turn_item_id FROM orchestration_v2_projection_turn_items error
    WHERE error.thread_id = r.thread_id AND error.run_id = r.run_id
      AND error.type = 'error' AND error.status = 'failed'
      AND error.node_id IS json_extract(r.payload_json, '$.rootNodeId')
    ORDER BY error.updated_at DESC, error.ordinal DESC, error.turn_item_id DESC LIMIT 1
  )
  WHERE r.status = 'failed' AND r.provider_instance_id IS NOT NULL
    AND json_extract(item.payload_json, '$.failure.class') = 'usage_limit'
    AND (julianday(json_extract(item.payload_json, '$.failure.resetAt')) - 2440587.5) * 86400 > ?1 - 600`;

/** The latest start of a run that went on to complete, by account. */
const PROVEN_ACCOUNTS_SQL = `
  SELECT provider_instance_id,
    (MAX(julianday(COALESCE(json_extract(payload_json, '$.startedAt'), requested_at))) - 2440587.5) * 86400
  FROM orchestration_v2_projection_runs
  WHERE status = 'completed' AND provider_instance_id IS NOT NULL
  GROUP BY provider_instance_id`;

// Same query and column order as the macOS app, so both read T3 identically.
const ACTIVITY_SQL = `
  WITH RECURSIVE edges(child, parent) AS MATERIALIZED (
    SELECT thread_id, CAST(json_extract(payload_json, '$.lineage.parentThreadId') AS TEXT)
    FROM orchestration_v2_projection_threads
    WHERE json_extract(payload_json, '$.lineage.relationshipToParent') = 'subagent'
      AND json_extract(payload_json, '$.settledOverride') IS NOT 'active'
  ), retired(thread_id) AS (
    SELECT thread_id FROM orchestration_v2_projection_threads
    WHERE thread_id IS NOT NULL AND (deleted_at IS NOT NULL OR archived_at IS NOT NULL
      OR json_extract(payload_json, '$.settledOverride') = 'settled')
    UNION
    SELECT edges.child FROM edges JOIN retired ON retired.thread_id = edges.parent
  )
  SELECT t.thread_id, r.status, pt.driver,
    COALESCE(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at),
    COALESCE(json_extract(t.payload_json, '$.worktreePath'), p.workspace_root),
    (EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests request
             WHERE request.thread_id = t.thread_id AND request.status = 'pending')
     OR EXISTS (SELECT 1 FROM orchestration_v2_projection_turn_items secret
                WHERE secret.thread_id = t.thread_id AND secret.run_id = r.run_id
                  AND secret.type = 'secret_request' AND secret.status = 'waiting'
                  AND r.status IN ('preparing', 'starting', 'running', 'waiting'))),
    json_extract(item.payload_json, '$.failure.class'),
    json_extract(item.payload_json, '$.failure.resetAt'),
    json_extract(t.payload_json, '$.limitRecovery.autoResume') = 1,
    json_extract(t.payload_json, '$.limitRecovery.runId'), r.run_id,
    json_extract(t.payload_json, '$.limitRecovery.resetAt'),
    t.provider_instance_id IS r.provider_instance_id,
    json_extract(t.payload_json, '$.snoozedUntil'),
    COALESCE((SELECT MAX(request.created_at) FROM orchestration_v2_projection_runtime_requests request
              WHERE request.thread_id = t.thread_id AND request.status = 'pending'),
             (SELECT MAX(secret.updated_at) FROM orchestration_v2_projection_turn_items secret
              WHERE secret.thread_id = t.thread_id AND secret.run_id = r.run_id
                AND secret.type = 'secret_request' AND secret.status = 'waiting')),
    json_array_length(pt.payload_json, '$.pendingBackgroundTasks'),
    json_extract(pt.payload_json, '$.updatedAt'),
    MAX(COALESCE((SELECT MAX(progress.updated_at) FROM orchestration_v2_projection_turn_items progress
                  WHERE progress.thread_id = t.thread_id AND progress.run_id = r.run_id), r.requested_at),
        COALESCE(json_extract(r.payload_json, '$.startedAt'), r.requested_at)),
    ${BACKGROUND_ACTIVITY_SQL},
    json_extract(pt.payload_json, '$.nativeThreadRef.nativeId'),
    r.provider_instance_id,
    (SELECT json_extract(session.payload_json, '$.lastError')
     FROM orchestration_v2_projection_provider_session_bindings binding
     JOIN orchestration_v2_projection_provider_sessions session
       ON session.provider_session_id = binding.provider_session_id
     WHERE binding.thread_id = t.thread_id AND session.provider_instance_id = t.provider_instance_id
     ORDER BY session.updated_at DESC, session.provider_session_id DESC LIMIT 1),
    json_extract(item.payload_json, '$.failure.message'),
    json_extract(t.payload_json, '$.modelSelection'),
    json_extract(t.payload_json, '$.lineage.relationshipToParent'),
    json_extract(t.payload_json, '$.limitRecovery.autoResume'),
    t.project_id
  FROM orchestration_v2_projection_threads t
  JOIN orchestration_v2_projection_runs r ON r.run_id = (
    SELECT latest.run_id FROM orchestration_v2_projection_runs latest
    WHERE latest.thread_id = t.thread_id AND latest.status <> 'queued'
      AND NOT (latest.status = 'cancelled' AND json_extract(latest.payload_json, '$.startedAt') IS NULL)
    ORDER BY latest.completed_at IS NULL DESC, latest.completed_at DESC,
             latest.ordinal DESC, latest.run_id DESC LIMIT 1
  )
  JOIN orchestration_v2_projection_provider_threads pt ON pt.provider_thread_id = r.provider_thread_id
  LEFT JOIN projection_projects p ON p.project_id = t.project_id
  LEFT JOIN orchestration_v2_projection_turn_items item ON item.turn_item_id = (
    SELECT error.turn_item_id FROM orchestration_v2_projection_turn_items error
    WHERE error.thread_id = t.thread_id AND error.run_id = r.run_id
      AND error.type = 'error' AND error.status = 'failed'
      AND error.node_id IS json_extract(r.payload_json, '$.rootNodeId')
    ORDER BY error.updated_at DESC, error.ordinal DESC, error.turn_item_id DESC LIMIT 1
  )
  WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
    AND json_extract(t.payload_json, '$.settledOverride') IS NOT 'settled'
    AND (r.status IN ('preparing', 'starting', 'running')
         OR NOT EXISTS (SELECT 1 FROM retired WHERE retired.thread_id = t.thread_id))
    AND (r.status IN ('preparing', 'starting', 'running', 'waiting', 'failed')
         OR (r.status IN ('completed', 'cancelled', 'interrupted')
             AND ((julianday(r.completed_at) - 2440587.5) * 86400 > ?1 - 120
                  OR json_array_length(pt.payload_json, '$.pendingBackgroundTasks') > 0
                  OR ${BACKGROUND_ACTIVITY_SQL} IS NOT NULL)))
    AND pt.driver IN ('codex', 'claudeAgent')`;

const OWNERSHIP_SQL = `
  SELECT json_extract(payload_json, '$.nativeThreadRef.nativeId'), driver
  FROM orchestration_v2_projection_provider_threads
  WHERE driver IN ('codex', 'claudeAgent')`;
