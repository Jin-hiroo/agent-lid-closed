// Port of Sources/LidCore/ProcessLookup.swift. Windows has no cheap way to read another
// process's parent and start time from Node.js, so AgentLidClosed.exe prints a snapshot.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

export function helperPath() {
  return process.env.AGENT_LID_EXE || path.join(appDir, 'AgentLidClosed.exe');
}

/** Shells and launchers between an agent and the hook it runs. */
const WRAPPERS = new Set(['bash.exe', 'sh.exe', 'dash.exe', 'zsh.exe', 'fish.exe', 'env.exe', 'cmd.exe',
  'powershell.exe', 'pwsh.exe', 'conhost.exe']);

/**
 * Every process: Map pid -> {pid, ppid, start, name}. `start` is unix seconds, 0 if unreadable.
 * Returns null when the helper isn't available.
 */
export function snapshot() {
  const exe = helperPath();
  if (!fs.existsSync(exe)) return null;
  const result = spawnSync(exe, ['proc'], { encoding: 'utf8', windowsHide: true, timeout: 10_000, maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0 || !result.stdout) return null;
  const map = new Map();
  for (const line of result.stdout.split('\n')) {
    const [pid, ppid, start, ...name] = line.split('\t');
    if (!pid) continue;
    map.set(Number(pid), { pid: Number(pid), ppid: Number(ppid), start: Number(start), name: name.join('\t').trim() });
  }
  return map;
}

/** Process lookups against one snapshot, or liveness only when the helper is missing. */
export class Processes {
  constructor(map = snapshot()) {
    this.map = map;
  }

  identity(pid) {
    if (!this.map) return null;
    const entry = this.map.get(pid);
    return entry && entry.start > 0 ? { pid, startTime: entry.start } : null;
  }

  isAlive(pid, startTime) {
    if (!(pid > 0)) return false;
    if (!this.map) {
      try {
        process.kill(pid, 0);
        return true;
      } catch (error) {
        return error.code === 'EPERM';
      }
    }
    const entry = this.map.get(pid);
    if (!entry) return false;
    // An unreadable start time can't prove reuse; a recorded one must match.
    if (!(entry.start > 0) || !(startTime > 0)) return true;
    return Math.abs(entry.start - startTime) < 1;
  }

  isDescendant(pid, ancestor) {
    if (!this.map) return false;
    let current = pid;
    for (let i = 0; i < 64; i += 1) {
      if (current === ancestor) return true;
      const entry = this.map.get(current);
      if (!entry || current <= 4 || entry.ppid === current) return false;
      current = entry.ppid;
    }
    return false;
  }

  /** The agent process that ran this hook: the nearest ancestor that isn't a shell. */
  hookOwner(fromPid = process.ppid) {
    if (!this.map) return null;
    let pid = fromPid;
    for (let i = 0; i < 10; i += 1) {
      const entry = this.map.get(pid);
      if (!entry || pid <= 4) return null;
      const name = entry.name.toLowerCase();
      // A version-manager shim (node.exe starting the real node.exe) is our direct parent and
      // started just before us; an agent running on Node.js started long before its hook.
      const self = this.map.get(process.pid);
      const shim = i === 0 && name === 'node.exe' && self?.start > 0 && entry.start > 0 && self.start - entry.start < 3;
      if (!WRAPPERS.has(name) && !shim) return this.identity(pid);
      pid = entry.ppid;
    }
    return null;
  }
}
