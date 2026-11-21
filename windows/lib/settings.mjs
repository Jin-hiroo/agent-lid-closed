import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function stateDirectory() {
  return process.env.AGENT_LID_STATE_DIR
    || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'AgentLidClosed');
}

export const paths = {
  get settings() { return path.join(stateDirectory(), 'settings.json'); },
  get status() { return path.join(stateDirectory(), 'status.json'); },
  get log() { return path.join(stateDirectory(), 'AgentLidClosed.log'); },
};

function readJSON(file) {
  try {
    let text = fs.readFileSync(file, 'utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** Writes through a temporary file and a rename, so readers never see half a file. */
export function writeJSONAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  try {
    fs.renameSync(temporary, file);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch { /* ignore */ }
    throw error;
  }
}

const DEFAULTS = { switchAccountAtLimit: true };

export function loadAppSettings() {
  const stored = readJSON(paths.settings);
  return { ...DEFAULTS, ...(stored && typeof stored === 'object' && !Array.isArray(stored) ? stored : {}) };
}

export function saveAppSetting(key, value) {
  const settings = loadAppSettings();
  settings[key] = value;
  writeJSONAtomic(paths.settings, settings);
  return settings;
}

export function log(message) {
  const line = `${new Date().toISOString()} ${message}\n`;
  try {
    fs.mkdirSync(stateDirectory(), { recursive: true });
    // Keep the log from growing without bound.
    try {
      if (fs.statSync(paths.log).size > 1_000_000) fs.renameSync(paths.log, `${paths.log}.1`);
    } catch { /* no log yet */ }
    fs.appendFileSync(paths.log, line);
  } catch { /* logging must never stop the app */ }
}

/**
 * Port of scripts/configure-t3.py: sets T3's native `autoResumeLimitedThreads`. T3's running
 * server watches this file. Uses T3's own reread-before-rename protocol to merge with
 * concurrent edits. Returns 'changed', 'unchanged', 'preserved' (explicit opt-out kept) or 'missing'.
 */
export function setT3AutoResume(settingsFile, enabled, { preserveChoice = false } = {}) {
  let file;
  try {
    file = fs.realpathSync(settingsFile);
  } catch {
    return 'missing';
  }
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const original = fs.readFileSync(file);
    let text = original.toString('utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    let settings;
    try {
      settings = JSON.parse(text);
    } catch {
      // JSON errors can include fragments of settings, which may hold secrets: never surface their text.
      throw new Error('T3 settings are not valid JSON');
    }
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
      throw new Error('T3 settings must be a JSON object');
    }
    if (preserveChoice && settings.autoResumeLimitedThreads === false) return 'preserved';
    if (settings.autoResumeLimitedThreads === enabled) return 'unchanged';
    settings.autoResumeLimitedThreads = enabled;
    const temporary = path.join(path.dirname(file), `.agent-lid-recovery-${process.pid}-${Date.now()}`);
    try {
      fs.writeFileSync(temporary, `${JSON.stringify(settings, null, 2)}\n`);
      if (!fs.readFileSync(file).equals(original)) continue;
      fs.renameSync(temporary, file);
      return 'changed';
    } finally {
      try { fs.unlinkSync(temporary); } catch { /* renamed or never written */ }
    }
  }
  throw new Error('T3 settings changed repeatedly; retry');
}
