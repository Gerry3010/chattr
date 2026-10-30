// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-41: what a message can make the agent do to its own machine.
//  M2 — chattr_fetch_media wrote to any path, through symlinks.
//  M3 — a message dated 2099 moved the fetch watermark past everything.
//  M4 — session.json was rewritten in place by several processes.
//  low — chat ids reached file paths unchecked.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// The state module reads its directory at import time: point it at a temp
// dir FIRST, never at the real agent profile.
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'chattr-agent-test-'));
process.env.CHATTR_AGENT_STATE_DIR = stateDir;

const { resolveOutPath, mediaRoot } = await import('../src/media.js');
const { clampToNow } = await import('../src/messages.js');
const { assertChatId, writeFileAtomic, sessionStorage } = await import('../src/state.js');

test('M2: out_path bleibt im Medienordner', () => {
  const root = mediaRoot();
  assert.equal(resolveOutPath('x/bild.jpg', 'c/m/bild.jpg.enc'), path.join(root, 'x', 'bild.jpg'));
  assert.throws(() => resolveOutPath(path.join(os.homedir(), '.bashrc'), 'c/m/a.enc'));
  assert.throws(() => resolveOutPath('../../etc/passwd', 'c/m/a.enc'));
  assert.equal(
    resolveOutPath(undefined, 'chat/../evil/../../x.enc', '../../.bashrc'),
    path.join(root, 'media', '.bashrc'),
  );
});

test('M3: Datum aus der Zukunft schiebt die Marke nicht voraus', () => {
  const now = new Date('2026-10-28T21:00:00Z');
  assert.equal(clampToNow('2099-01-01T00:00:00Z', now), now.toISOString());
  assert.equal(clampToNow('2026-10-28T20:59:00Z', now), '2026-10-28T20:59:00Z');
  assert.equal(clampToNow('kein Datum', now), now.toISOString());
});

test('M4: Sitzung wird atomar geschrieben, Lock wird aufgeräumt', () => {
  sessionStorage.setItem('k', 'v1');
  sessionStorage.setItem('k2', 'v2');
  assert.equal(sessionStorage.getItem('k'), 'v1');
  assert.equal(sessionStorage.getItem('k2'), 'v2');
  const leftovers = fs.readdirSync(stateDir).filter((f) => f.endsWith('.tmp') || f.endsWith('.lock'));
  assert.deepEqual(leftovers, []);
  const f = path.join(stateDir, 'x.json');
  writeFileAtomic(f, '{"a":1}');
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
});

test('Chat-IDs sind UUIDs, sonst kein Dateipfad', () => {
  assert.equal(assertChatId('f92834e8-0000-4000-8000-000000000000'), 'f92834e8-0000-4000-8000-000000000000');
  assert.throws(() => assertChatId('../../keys'));
});
