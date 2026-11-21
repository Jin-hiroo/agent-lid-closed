// Port of scripts/hooks.py: adds or removes Agent Lid Closed hooks in Claude Code settings.json
// and Codex hooks.json, preserving other settings, and records every file in a manifest.
// Windows hook commands must work in Git Bash, cmd.exe and PowerShell alike, so they are
// `node "C:/path/agent-lid-hook.mjs"` with forward slashes, and the wrapped status line is
// carried as base64 (no shell quoting needed).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { stateDirectory } from './settings.mjs';

const MARKS = ['claude-lid-hook', 'agent-lid-hook'];
const CLAUDE_EVENTS = {
  SessionStart: null, UserPromptSubmit: null, PreToolUse: '*', PostToolUse: '*', PostToolUseFailure: '*',
  Notification: null, Elicitation: null, ElicitationResult: null, SubagentStart: null, SubagentStop: null,
  Stop: null, StopFailure: null, SessionEnd: null,
};
const CODEX_EVENTS = Object.fromEntries(['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'PermissionRequest', 'SubagentStart', 'SubagentStop', 'PreCompact', 'PostCompact', 'Stop', 'Interrupt'].map((e) => [e, null]));

export function manifestPath() {
  return path.join(stateDirectory(), 'hook-targets.json');
}

export function home() {
  return process.env.AGENT_LID_HOME || os.homedir();
}

const forward = (p) => p.replace(/\\/g, '/');

/** The command the hooks run. */
export function hookCommand(hookScript, provider) {
  return `node "${forward(hookScript)}"${provider === 'codex' ? ' --provider codex' : ''}`;
}

const isOurs = (command) => typeof command === 'string' && MARKS.some((mark) => command.includes(mark));

/** Recover the exact previous status line from our wrapper, including display options. */
function unwrapStatusLine(settings) {
  const status = settings.statusLine;
  if (!status || typeof status !== 'object' || !isOurs(status.command) || !/\bstatusline\b/.test(status.command)) return;
  const match = /--original-b64\s+([A-Za-z0-9+/=]+)/.exec(status.command);
  if (!match) {
    delete settings.statusLine;
    return;
  }
  try {
    settings.statusLine = JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } catch {
    // A manually edited command is the user's to keep.
  }
}

export function strip(settings) {
  unwrapStatusLine(settings);
  const hooks = settings.hooks ?? {};
  for (const event of Object.keys(hooks)) {
    const kept = [];
    for (const group of hooks[event]) {
      const entries = (group.hooks ?? []).filter((h) => !isOurs(h.command));
      if (entries.length) kept.push({ ...group, hooks: entries });
    }
    if (kept.length) hooks[event] = kept;
    else delete hooks[event];
  }
  if ('hooks' in settings && !Object.keys(hooks).length) delete settings.hooks;
}

export function validate(settings) {
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)
    || (settings.hooks !== undefined && (typeof settings.hooks !== 'object' || Array.isArray(settings.hooks) || settings.hooks === null))) {
    throw new Error('Expected a JSON object containing a hooks object');
  }
  for (const groups of Object.values(settings.hooks ?? {})) {
    if (!Array.isArray(groups)) throw new Error('Hook events must contain arrays of matcher groups');
    for (const group of groups) {
      if (!group || typeof group !== 'object' || !Array.isArray(group.hooks)) throw new Error('Each matcher group must contain a hooks array');
      for (const handler of group.hooks) {
        if (!handler || typeof handler !== 'object' || (handler.command !== undefined && typeof handler.command !== 'string')) {
          throw new Error('Expected hook handler objects with string commands');
        }
      }
    }
  }
  const status = settings.statusLine;
  if (status !== undefined && (!status || typeof status !== 'object' || status.type !== 'command' || typeof status.command !== 'string')) {
    throw new Error('Expected a command statusLine; existing settings were preserved');
  }
}

export function install(settings, command, provider = 'claude') {
  strip(settings);
  if (provider === 'claude') {
    const original = settings.statusLine;
    let wrapper = `${command} statusline`;
    if (original !== undefined) {
      wrapper += ` --original-b64 ${Buffer.from(JSON.stringify(original), 'utf8').toString('base64')}`;
    }
    settings.statusLine = { ...(original ?? {}), type: 'command', command: wrapper };
  }
  settings.hooks ??= {};
  const events = provider === 'codex' ? CODEX_EVENTS : CLAUDE_EVENTS;
  for (const [event, matcher] of Object.entries(events)) {
    const group = matcher ? { matcher } : {};
    // Windows starts Node.js more slowly than the macOS binary; still well under a second.
    const timeout = provider === 'codex' && (event === 'SessionEnd' || event === 'Interrupt') ? 3 : 5;
    group.hooks = [{ type: 'command', command, timeout }];
    (settings.hooks[event] ??= []).push(group);
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = path.join(path.dirname(file), `.agent-lid-${process.pid}-${Date.now()}`);
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
    fs.renameSync(temporary, file);
  } finally {
    try { fs.unlinkSync(temporary); } catch { /* renamed */ }
  }
}

function readJSONFile(file) {
  let text = fs.readFileSync(file, 'utf8');
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  return JSON.parse(text);
}

/** The recorded files. `strict` throws for a manifest that exists but can't be read, instead of
 *  treating it as empty (which, when written back, would forget files that still have hooks). */
export function readManifest(file = manifestPath(), { strict = false } = {}) {
  const targets = { claude: [], codex: [] };
  let value;
  try {
    value = readJSONFile(file);
  } catch (error) {
    if (strict && error.code !== 'ENOENT') throw new Error(`${file} を読み取れません`);
    return targets;
  }
  for (const provider of Object.keys(targets)) {
    if (Array.isArray(value?.[provider])) targets[provider] = value[provider].filter((p) => typeof p === 'string');
  }
  return targets;
}

function record(manifest, provider, file, installed) {
  if (!manifest) return;
  const targets = readManifest(manifest, { strict: true });
  for (const name of Object.keys(targets)) targets[name] = targets[name].filter((p) => p.toLowerCase() !== file.toLowerCase());
  if (installed) targets[provider].push(file);
  writeJSON(manifest, targets);
}

export function hasHooks(file) {
  try {
    const settings = readJSONFile(file);
    const groups = settings?.hooks;
    if (!groups || typeof groups !== 'object') return false;
    return Object.values(groups).some((event) => Array.isArray(event) && event.some((group) =>
      Array.isArray(group?.hooks) && group.hooks.some((handler) => isOurs(handler?.command))));
  } catch {
    return false;
  }
}

/** Adds (`install`) or removes hooks in one file. Returns the absolute path. */
export function apply(action, file, { provider = 'claude', hookScript, manifest = manifestPath() } = {}) {
  const target = path.resolve(file);
  let real = target;
  try { real = fs.realpathSync(target); } catch { /* new file */ }
  let settings = {};
  if (fs.existsSync(real)) {
    settings = readJSONFile(real);
    validate(settings);
    fs.copyFileSync(real, `${real}.bak`);
  }
  if (action === 'install') install(settings, hookCommand(hookScript, provider), provider);
  else strip(settings);
  writeJSON(real, settings);
  record(manifest, provider, target, action === 'install');
  return target;
}

function onPath(command) {
  for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
    for (const ext of ['.exe', '.cmd', '.bat', '']) {
      try {
        if (dir && fs.statSync(path.join(dir, command + ext)).isFile()) return true;
      } catch { /* not here */ }
    }
  }
  return false;
}

const isDirectory = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };

export function defaultHookFile(provider, base = home()) {
  return provider === 'claude' ? path.join(base, '.claude', 'settings.json') : path.join(base, '.codex', 'hooks.json');
}

/** The tool's folder or command exists. */
export function isInstalled(provider, base = home()) {
  const name = provider === 'claude' ? 'claude' : 'codex';
  return isDirectory(path.join(base, provider === 'claude' ? '.claude' : '.codex')) || onPath(name)
    || fs.existsSync(path.join(base, '.local', 'bin', `${name}.exe`));
}

function unique(paths) {
  const result = [];
  for (const p of paths) {
    if (!p || !path.isAbsolute(p) || /[\r\n]/.test(p)) continue;
    const normal = path.normalize(p);
    if (!result.some((r) => r.toLowerCase() === normal.toLowerCase())) result.push(normal);
  }
  return result;
}

/** Files to install hooks into: present tools, files that already have them, and named folders. */
export function plan({ manifest = manifestPath(), claudeDirs = [], noClaude = false, noCodex = false, forceCodex = false } = {}) {
  const base = home();
  const recorded = readManifest(manifest);
  const claude = [];
  if (!noClaude) {
    const claudeDefault = defaultHookFile('claude', base);
    if (isInstalled('claude', base) || hasHooks(claudeDefault)) claude.push(claudeDefault);
    if (process.env.CLAUDE_CONFIG_DIR) claude.push(path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json'));
    claude.push(...recorded.claude.filter((p) => fs.existsSync(p)));
    claude.push(...claudeDirs.map((d) => path.join(d, 'settings.json')));
  }
  const codex = [];
  if (!noCodex) {
    const codexDefault = path.join(process.env.CODEX_HOME || path.join(base, '.codex'), 'hooks.json');
    if (forceCodex || onPath('codex') || isDirectory(path.dirname(codexDefault)) || hasHooks(codexDefault)) codex.push(codexDefault);
    codex.push(...recorded.codex.filter((p) => fs.existsSync(p)));
  }
  return { claude: unique(claude), codex: unique(codex) };
}

/** Files to remove hooks from: recorded ones, the defaults, and this shell's config folders.
 *  Only a missing file counts as absent: a manifest or hook file that exists but can't be read
 *  throws or stays in the list, so uninstalling fails visibly instead of leaving hooks behind. */
export function targets(manifest = manifestPath()) {
  const base = home();
  const recorded = { claude: [], codex: [] };
  let text = null;
  try {
    text = fs.readFileSync(manifest, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw new Error(`${manifest} を読み取れません (${error.code})`);
  }
  if (text != null) {
    let value;
    try {
      value = JSON.parse(text.replace(/^﻿/, ''));
    } catch {
      throw new Error(`${manifest} を読み取れません`);
    }
    for (const provider of Object.keys(recorded)) {
      if (Array.isArray(value?.[provider])) recorded[provider] = value[provider].filter((p) => typeof p === 'string');
    }
  }
  const paths = [...recorded.claude.map((p) => ['claude', p]), ...recorded.codex.map((p) => ['codex', p]),
    ['claude', defaultHookFile('claude', base)], ['codex', defaultHookFile('codex', base)]];
  if (process.env.CLAUDE_CONFIG_DIR) paths.push(['claude', path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json')]);
  if (process.env.CODEX_HOME) paths.push(['codex', path.join(process.env.CODEX_HOME, 'hooks.json')]);
  const seen = new Set();
  return paths.filter(([, p]) => {
    const key = p.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    try {
      return MARKS.some((m) => fs.readFileSync(p, 'utf8').includes(m));
    } catch (error) {
      return error.code !== 'ENOENT';
    }
  }).map(([provider, file]) => ({ provider, file }));
}

/** What the Settings window lists: the default file for each tool, then every recorded one. */
export function hookFiles(manifest = manifestPath()) {
  const base = home();
  const recorded = readManifest(manifest);
  const files = [];
  for (const provider of ['claude', 'codex']) {
    const defaultPath = defaultHookFile(provider, base);
    const installed = isInstalled(provider, base);
    for (const p of unique([defaultPath, ...recorded[provider]])) {
      files.push({ tool: provider, path: p, hasHooks: hasHooks(p), isDefault: p.toLowerCase() === defaultPath.toLowerCase(), toolInstalled: installed });
    }
  }
  return files;
}
