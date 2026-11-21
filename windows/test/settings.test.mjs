import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setT3AutoResume } from '../lib/settings.mjs';

function temporarySettings(content) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-lid-t3-'));
  const file = path.join(dir, 'settings.json');
  if (content !== undefined) fs.writeFileSync(file, content);
  return file;
}

test('enables T3 auto-resume and keeps every other setting', () => {
  const file = temporarySettings(JSON.stringify({ a: 1, providerInstances: { x: { driver: 'codex' } } }));
  assert.equal(setT3AutoResume(file, true), 'changed');
  const written = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(written, { a: 1, providerInstances: { x: { driver: 'codex' } }, autoResumeLimitedThreads: true });
  assert.equal(setT3AutoResume(file, true), 'unchanged');
  assert.deepEqual(fs.readdirSync(path.dirname(file)), ['settings.json'], 'no temporary files left behind');
});

test('preserves an explicit opt-out at startup, but the menu can change it', () => {
  const file = temporarySettings(JSON.stringify({ autoResumeLimitedThreads: false }));
  assert.equal(setT3AutoResume(file, true, { preserveChoice: true }), 'preserved');
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).autoResumeLimitedThreads, false);
  assert.equal(setT3AutoResume(file, true), 'changed');
  assert.equal(setT3AutoResume(file, false), 'changed');
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).autoResumeLimitedThreads, false);
});

test('missing or invalid settings are left alone without leaking their text', () => {
  assert.equal(setT3AutoResume(temporarySettings(), true), 'missing');
  const file = temporarySettings('{"token":"secret-value",');
  assert.throws(() => setT3AutoResume(file, true), (error) => !error.message.includes('secret-value'));
  assert.equal(fs.readFileSync(file, 'utf8'), '{"token":"secret-value",');
});
