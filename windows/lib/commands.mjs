// Port of Sources/AgentLidClosed/T3Commands.swift. Sends commands through T3's own
// WebSocket API, the way its app does. Each delivery gets a five-minute credential scoped
// to orchestration from T3's CLI and revokes it afterwards; nothing is stored or logged.
// T3 deduplicates command IDs, so redelivery is safe.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { serverRuntime } from './t3.mjs';

const quote = (s) => (/[\s&|<>^()]/.test(s) ? `"${s}"` : s);
// cmd.exe expands %NAME% and may treat ! specially even inside quotes, and can't quote a quote.
const unsafeForCmd = (s) => /[%!"\r\n]/.test(s);

/** Runs T3's `t3.cmd` and resolves with its standard output, or null on failure or after 20 s. */
function runCLI(cli, args) {
  return new Promise((resolve) => {
    if ([cli, ...args].some(unsafeForCmd)) {
      resolve(null);
      return;
    }
    const line = [cli, ...args].map(quote).join(' ');
    let child;
    try {
      child = spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `"${line}"`], {
        windowsHide: true, windowsVerbatimArguments: true, stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch {
      resolve(null);
      return;
    }
    let output = '';
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      // taskkill /T also ends the T3 process cmd.exe started.
      try { spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' }); } catch { /* ignore */ }
      finish(null);
    }, 20_000);
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.on('error', () => finish(null));
    child.on('close', (code) => finish(code === 0 ? output : null));
  });
}

function outcomeOf(exit) {
  switch (exit?._tag) {
    case 'Success':
      return { kind: 'accepted' };
    case 'Failure': {
      const causes = Array.isArray(exit.cause) ? exit.cause : [];
      const failure = causes.find((c) => c?._tag === 'Fail')?.error;
      if (failure && typeof failure === 'object') {
        return { kind: 'rejected', reason: failure.message ?? failure._tag ?? 'refused' };
      }
      // An interrupted request was not processed.
      if (causes.some((c) => c?._tag === 'Interrupt')) return { kind: 'failed', reason: 'T3 interrupted the request' };
      return { kind: 'rejected', reason: "T3 couldn't process the command" };
    }
    default:
      return { kind: 'failed', reason: 'T3 sent an unexpected reply' };
  }
}

function parseMessages(data) {
  try {
    const text = typeof data === 'string' ? data : new TextDecoder().decode(data);
    const decoded = JSON.parse(text);
    const list = Array.isArray(decoded) ? decoded : [decoded];
    return list.filter((m) => m && typeof m === 'object' && !Array.isArray(m));
  } catch {
    return [];
  }
}

function send(commands, url, token, confirm) {
  return new Promise((resolve) => {
    const outcomes = {};
    const pending = new Map(); // RPC request ID -> command ID
    let socket;
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      try { socket?.close(); } catch { /* ignore */ }
      for (const command of commands) outcomes[command.id] ??= { kind: 'failed', reason: "Couldn't reach T3 Code" };
      resolve(outcomes);
    };
    // A stalled server ends the exchange.
    const timeout = setTimeout(finish, 15_000);
    try {
      socket = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
    } catch {
      finish();
      return;
    }
    // Binary frames arrive as ArrayBuffer and are decoded like text ones.
    socket.binaryType = 'arraybuffer';
    let handshake = true;
    socket.onopen = () => {
      // A Pong proves the handshake finished, so the confirmation covers everything but the send itself.
      socket.send('{"_tag":"Ping"}');
    };
    socket.onmessage = (event) => {
      handle(event).catch(() => {
        for (const commandID of pending.values()) outcomes[commandID] = { kind: 'failed', reason: 'T3 closed the connection' };
        pending.clear();
        finish();
      });
    };
    const handle = async (event) => {
      for (const message of parseMessages(event.data)) {
        if (handshake) {
          if (message._tag !== 'Pong') continue;
          handshake = false;
          let wanted;
          try {
            wanted = await confirm();
          } catch {
            // Couldn't check: retry later rather than treat the switch as withdrawn.
            for (const command of commands) outcomes[command.id] = { kind: 'failed', reason: 'T3 activity unavailable' };
            finish();
            return;
          }
          if (settled) return;
          commands.forEach((command, index) => {
            if (!wanted.has(command.id)) {
              outcomes[command.id] = { kind: 'withdrawn' };
              return;
            }
            const requestID = String(index + 1);
            socket.send(JSON.stringify({
              _tag: 'Request', id: requestID, tag: 'orchestration.dispatchCommand',
              payload: JSON.parse(command.json), headers: [],
            }));
            pending.set(requestID, command.id);
          });
          if (pending.size === 0) finish();
          return;
        }
        switch (message._tag) {
          case 'Exit': {
            const commandID = pending.get(message.requestId);
            if (!commandID) break;
            pending.delete(message.requestId);
            outcomes[commandID] = outcomeOf(message.exit);
            if (pending.size === 0) finish();
            break;
          }
          case 'Ping':
            socket.send('{"_tag":"Pong"}');
            break;
          case 'Defect':
          case 'ClientProtocolError':
            for (const commandID of pending.values()) outcomes[commandID] = { kind: 'failed', reason: 'T3 closed the connection' };
            pending.clear();
            finish();
            break;
          default:
            break;
        }
      }
    };
    socket.onerror = () => finish();
    socket.onclose = () => finish();
  });
}

/**
 * Returns an outcome ({kind: accepted|rejected|failed|withdrawn, reason?}) for every command ID.
 * `confirm` runs once the connection is ready, just before sending, and resolves to the IDs still
 * wanted, so a change made meanwhile withdraws a command.
 */
export async function dispatch(commands, directory, confirm) {
  const all = (outcome) => Object.fromEntries(commands.map((c) => [c.id, outcome]));
  const runtime = serverRuntime(directory);
  if (!runtime) return all({ kind: 'failed', reason: "T3 Code isn't running" });
  const base = path.dirname(directory);
  const cli = path.join(base, 'bin', 't3.cmd');
  if (!fs.existsSync(cli)) {
    return all({ kind: 'failed', reason: "T3's t3 command is missing; open T3 Code once to reinstall it" });
  }
  const output = await runCLI(cli, ['auth', 'session', 'issue', '--base-dir', base,
    '--scope', 'orchestration:read', '--scope', 'orchestration:operate',
    '--ttl', '5m', '--label', 'Agent Lid Closed', '--json']);
  let issued;
  try {
    issued = JSON.parse(output);
  } catch {
    issued = null;
  }
  // The output contains the credential: never log it.
  if (!issued || typeof issued.token !== 'string' || typeof issued.sessionId !== 'string') {
    return all({ kind: 'failed', reason: "T3 didn't issue a command credential" });
  }
  // The credential goes only to the same T3 server it was issued for.
  const current = serverRuntime(directory);
  let outcomes;
  if (!current || current.pid !== runtime.pid || current.port !== runtime.port || current.startedAt !== runtime.startedAt) {
    outcomes = all({ kind: 'failed', reason: 'T3 Code restarted' });
  } else {
    const url = `ws://127.0.0.1:${runtime.port}/ws?orchestrationProtocol=2`;
    outcomes = await send(commands, url, issued.token, confirm);
  }
  await runCLI(cli, ['auth', 'session', 'revoke', '--base-dir', base, issued.sessionId]);
  return outcomes;
}
