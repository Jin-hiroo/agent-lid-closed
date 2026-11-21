// Port of Sources/LidCore/Transcript.swift and the Controller's InterruptCache.
// No hook fires when you press Esc in Claude Code, so its transcript is the only way to see it.
import fs from 'node:fs';

const MARKER = '[Request interrupted by user';
const TAIL_BYTES = 256 * 1024;

/** True if the newest message in a Claude Code transcript (JSONL) is its interrupt marker. */
export function endsWithInterrupt(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - TAIL_BYTES);
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    const lines = buffer.toString('utf8').split('\n').filter((line) => line.length);
    if (start > 0 && lines.length) lines.shift(); // cut off mid-line
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[lines.length - 1 - index];
      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        // An unreadable newest line means it's still being written; don't guess.
        if (index === 0) return false;
        continue;
      }
      if (!entry || typeof entry !== 'object' || entry.isSidechain === true || entry.isMeta === true) continue;
      if (entry.type === 'assistant') return false;
      if (entry.type === 'user') {
        const content = entry.message?.content;
        if (typeof content === 'string') return content.startsWith(MARKER);
        return Array.isArray(content) && content.some((item) => typeof item?.text === 'string' && item.text.startsWith(MARKER));
      }
    }
    return false;
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** Re-reads a transcript only when it has changed. */
export class InterruptCache {
  cache = new Map();

  endsWithInterrupt(file) {
    let stat;
    try { stat = fs.statSync(file); } catch { stat = { mtimeMs: 0, size: 0 }; }
    const hit = this.cache.get(file);
    if (hit && hit.modified === stat.mtimeMs && hit.size === stat.size) return hit.interrupted;
    const interrupted = endsWithInterrupt(file);
    this.cache.set(file, { modified: stat.mtimeMs, size: stat.size, interrupted });
    return interrupted;
  }
}
