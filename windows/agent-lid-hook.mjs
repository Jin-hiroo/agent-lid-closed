#!/usr/bin/env node
// Port of Sources/agent-lid-hook/main.swift. Claude Code and Codex run this on hook events
// (payload JSON on stdin) to record what each session is doing. Event mode must stay fast,
// print nothing to stdout (some events add stdout to Claude's context) and always exit 0.
//
//   node agent-lid-hook.mjs [--provider claude|codex]   handle one event from stdin
//   node agent-lid-hook.mjs status                      show all sessions and the sleep decision
//   node agent-lid-hook.mjs statusline [--original-b64 X]   capture quota data, then run the original status line
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyHook, blockingReset, hookAction, parseHookInput, saveStatusLine, sessionKey, SessionStore } from './lib/sessions.mjs';

function readStdin() {
  try {
    return fs.readFileSync(0);
  } catch {
    return Buffer.alloc(0);
  }
}

function parseJSON(buffer) {
  try {
    let text = buffer.toString('utf8');
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function handleHook(provider) {
  const input = parseHookInput(parseJSON(readStdin()));
  if (!input || !input.sessionID) return;
  input.sessionID = sessionKey(provider, input.sessionID);
  const action = hookAction(input, provider);
  if (action.kind === 'ignore') return;
  const store = new SessionStore();
  // Finding the agent process costs a process snapshot on Windows, so it is done when the
  // owner can change (a new or resumed session, a new prompt) or isn't known yet.
  let owner = null;
  if (action.kind !== 'endSession' && action.kind !== 'subagentDone') {
    const existing = store.load(input.sessionID);
    if (!existing || !(existing.pid > 0) || ['SessionStart', 'UserPromptSubmit'].includes(input.event)) {
      const { Processes } = await import('./lib/process.mjs');
      owner = new Processes().hookOwner();
    }
  }
  await store.withLock(() => applyHook(action, input, owner, store, Date.now() / 1000, provider));
}

/** Capture only quota fields, then replay the unchanged payload to the user's status line. */
async function handleStatusLine(originalB64) {
  const data = readStdin();
  const raw = parseJSON(data);
  try { await saveStatusLine(raw, new SessionStore(), Date.now() / 1000); } catch { /* display still runs */ }
  if (originalB64) {
    let config;
    try { config = JSON.parse(Buffer.from(originalB64, 'base64').toString('utf8')); } catch { return; }
    const command = config?.command;
    if (typeof command !== 'string' || !command) return;
    // Claude Code runs status lines in Git Bash when it's there; MSYSTEM marks that shell. For cmd,
    // /s with outer quotes keeps the command's own quotes intact.
    const [shell, shellArgs] = process.env.MSYSTEM ? ['bash', ['-c', command]]
      : [process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `"${command}"`]];
    const result = spawnSync(shell, shellArgs, { input: data, stdio: ['pipe', 'inherit', 'inherit'], windowsHide: true,
      windowsVerbatimArguments: !process.env.MSYSTEM });
    if (result.error) process.stderr.write(`agent-lid-hook statusline: ${result.error.message}\n`);
  } else {
    const reset = raw?.rate_limits ? blockingReset(raw.rate_limits, Date.now() / 1000) : null;
    if (reset != null) {
      const date = new Date(reset * 1000);
      const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
      process.stdout.write(`Claude usage limit · resets ${time}\n`);
    }
  }
}

const args = process.argv.slice(2);
try {
  if (args.length === 0) {
    await handleHook('claude');
  } else if (args[0] === 'status') {
    const here = path.dirname(fileURLToPath(import.meta.url));
    spawn(process.execPath, [path.join(here, 'agent-lid.mjs'), 'status'], { stdio: 'inherit' });
  } else if (args[0] === 'statusline') {
    await handleStatusLine(args[1] === '--original-b64' ? args[2] : null);
  } else if (args.length === 2 && args[0] === '--provider' && ['claude', 'codex'].includes(args[1])) {
    await handleHook(args[1]);
  } else {
    process.stderr.write('usage: agent-lid-hook [status | statusline | --provider claude|codex]\n');
    process.exitCode = 64;
  }
} catch (error) {
  // Never block the agent.
  process.stderr.write(`agent-lid-hook: ${error?.message ?? error}\n`);
}
