#!/usr/bin/env node
// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Standalone listener: spawns the built mcp_server once, then loops
// chattr_wait against a single chat, printing one line per new message.
// Meant to be watched with the Monitor tool (each stdout line = one event).
//
//   node scripts/listen.mjs <chat_id>

import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverEntry = path.join(__dirname, '../build/mcp_server/src/index.js');

const chatId = process.argv[2];
if (!chatId) {
  console.error('Usage: node scripts/listen.mjs <chat_id>');
  process.exit(1);
}

const proc = spawn(process.execPath, [serverEntry], { stdio: ['pipe', 'pipe', 'pipe'] });
proc.stderr.on('data', (c) => {
  const t = c.toString();
  if (!t.includes('ExperimentalWarning') && !t.includes('running on stdio')) process.stderr.write(t);
});

let nextId = 1;
const pending = new Map();
let buffer = '';

proc.stdout.on('data', (chunk) => {
  buffer += chunk.toString();
  let idx;
  while ((idx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  }
});

function send(method, params, id) {
  const m = { jsonrpc: '2.0', method };
  if (params !== undefined) m.params = params;
  if (id !== undefined) {
    m.id = id;
    const p = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    proc.stdin.write(JSON.stringify(m) + '\n');
    return p;
  }
  proc.stdin.write(JSON.stringify(m) + '\n');
}

async function callTool(name, args = {}) {
  const id = nextId++;
  const result = await send('tools/call', { name, arguments: args }, id);
  const text = result?.content?.[0]?.text;
  if (result?.isError) throw new Error(`${name} failed: ${text}`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function main() {
  await send('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'listen', version: '0' } }, nextId++);
  send('notifications/initialized');

  console.log(`listening on chat ${chatId} (Ctrl-C to stop)...`);

  for (;;) {
    const messages = await callTool('chattr_wait', { chat_id: chatId, timeout_s: 270 });
    for (const m of messages) {
      const ts = new Date(m.createdAt).toLocaleTimeString('de-DE');
      console.log(`[${ts}] ${formatEntry(m)}`);
    }
  }
}

// System messages (joins/approvals/key rotation) have no sender and carry a
// {"action":...,"subject_name":...} JSON payload as their text — same shape
// SystemMessage.formattedText handles on the Dart side (see
// lib/features/messages/message_model.dart). Mirror it here for readability
// instead of printing the raw JSON.
function formatEntry(m) {
  if (m.senderId !== null) return `${m.senderName ?? m.senderId}: ${m.text}`;
  try {
    const { action, subject_name: subject } = JSON.parse(m.text);
    const label = subject ?? 'someone';
    switch (action) {
      case 'joined':
        return `[system] ${label} joined`;
      case 'left':
        return `[system] ${label} left`;
      case 'removed':
        return `[system] ${label} was removed`;
      case 'promoted':
        return `[system] ${label} was promoted`;
      case 'approved':
        return `[system] ${label} was approved`;
      case 'keys_rotated':
        return `[system] ${label} rotated their keys`;
      default:
        return `[system] ${action ?? m.text}`;
    }
  } catch {
    return `[system] ${m.text}`;
  }
}

process.on('SIGINT', () => {
  proc.kill();
  process.exit(0);
});

main().catch((err) => {
  console.error('[Fatal]', err);
  proc.kill();
  process.exit(1);
});
