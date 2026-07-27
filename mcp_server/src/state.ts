// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Per-machine agent state: session (Supabase refresh token = stable identity),
// per-chat keypairs, and the local plaintext message store (the only copy
// once mark_message_read clears the server ciphertext — same model as the
// app). Never committed to any repo; lives in config.stateDir
// (~/.config/chattr-agent/<profile>/ by default).

import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';
import type { ChatKeyPair, IdentityKeyPair } from './crypto_port.js';
import { config } from './config.js';

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true, mode: 0o700 });
}

function keysDir(): string {
  const dir = path.join(config.stateDir, 'keys');
  ensureDir(dir);
  return dir;
}

// ── Session storage (Supabase's generic key-value storage interface) ───────
// supabase-js persists the refresh token through this adapter so the agent's
// identity survives restarts without re-running chattr_init.

const sessionFile = () => path.join(config.stateDir, 'session.json');

function readSessionStore(): Record<string, string> {
  try {
    return JSON.parse(fs.readFileSync(sessionFile(), 'utf8'));
  } catch {
    return {};
  }
}

function writeSessionStore(store: Record<string, string>) {
  ensureDir(config.stateDir);
  fs.writeFileSync(sessionFile(), JSON.stringify(store, null, 2), { mode: 0o600 });
}

/** Implements supabase-js's SupportedStorage interface backed by session.json. */
export const sessionStorage = {
  getItem(key: string): string | null {
    return readSessionStore()[key] ?? null;
  },
  setItem(key: string, value: string): void {
    const store = readSessionStore();
    store[key] = value;
    writeSessionStore(store);
  },
  removeItem(key: string): void {
    const store = readSessionStore();
    delete store[key];
    writeSessionStore(store);
  },
};

// ── Per-chat keypairs ────────────────────────────────────────────────────

function keyFile(chatId: string): string {
  return path.join(keysDir(), `${chatId}.json`);
}

export function loadChatKeyPair(chatId: string): ChatKeyPair | null {
  try {
    return JSON.parse(fs.readFileSync(keyFile(chatId), 'utf8'));
  } catch {
    return null;
  }
}

export function saveChatKeyPair(chatId: string, pair: ChatKeyPair): void {
  fs.writeFileSync(keyFile(chatId), JSON.stringify(pair, null, 2), { mode: 0o600 });
}

// ── Long-term identity keypair (audit C1/H1) ─────────────────────────────
// One Ed25519 keypair per agent profile; signs the agent's per-chat KEM keys
// and outgoing messages. Mirrors the app's IdentityKeyManager.

const identityFile = () => path.join(config.stateDir, 'identity.json');

export function loadIdentityKeyPair(): IdentityKeyPair | null {
  try {
    return JSON.parse(fs.readFileSync(identityFile(), 'utf8'));
  } catch {
    return null;
  }
}

export function saveIdentityKeyPair(pair: IdentityKeyPair): void {
  ensureDir(config.stateDir);
  fs.writeFileSync(identityFile(), JSON.stringify(pair, null, 2), { mode: 0o600 });
}

// ── Local plaintext store (store.sqlite) ────────────────────────────────

let _db: DatabaseSync | null = null;

export function db(): DatabaseSync {
  if (_db) return _db;
  ensureDir(config.stateDir);
  _db = new DatabaseSync(path.join(config.stateDir, 'store.sqlite'));
  _db.exec(`
    CREATE TABLE IF NOT EXISTS messages (
      message_id TEXT NOT NULL,
      chat_id TEXT NOT NULL,
      sender_id TEXT,
      sender_name TEXT,
      direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
      created_at TEXT NOT NULL,
      plaintext TEXT NOT NULL,
      PRIMARY KEY (message_id, chat_id)
    );
    CREATE INDEX IF NOT EXISTS idx_messages_chat_created ON messages(chat_id, created_at);
    CREATE TABLE IF NOT EXISTS fetch_state (
      chat_id TEXT PRIMARY KEY,
      last_created_at TEXT
    );
  `);
  return _db;
}

export interface StoredMessage {
  messageId: string;
  chatId: string;
  senderId: string | null;
  senderName: string | null;
  direction: 'in' | 'out';
  createdAt: string;
  plaintext: string;
}

export function saveMessage(msg: StoredMessage): void {
  db()
    .prepare(
      `INSERT OR REPLACE INTO messages (message_id, chat_id, sender_id, sender_name, direction, created_at, plaintext)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(msg.messageId, msg.chatId, msg.senderId, msg.senderName, msg.direction, msg.createdAt, msg.plaintext);
}

export function listMessages(chatId: string, limit = 50): StoredMessage[] {
  const rows = db()
    .prepare(
      `SELECT message_id, chat_id, sender_id, sender_name, direction, created_at, plaintext
       FROM messages WHERE chat_id = ? ORDER BY created_at DESC LIMIT ?`,
    )
    .all(chatId, limit) as Array<{
    message_id: string;
    chat_id: string;
    sender_id: string | null;
    sender_name: string | null;
    direction: 'in' | 'out';
    created_at: string;
    plaintext: string;
  }>;
  return rows
    .map((r) => ({
      messageId: r.message_id,
      chatId: r.chat_id,
      senderId: r.sender_id,
      senderName: r.sender_name,
      direction: r.direction,
      createdAt: r.created_at,
      plaintext: r.plaintext,
    }))
    .reverse();
}

export function getFetchWatermark(chatId: string): string | null {
  const row = db().prepare(`SELECT last_created_at FROM fetch_state WHERE chat_id = ?`).get(chatId) as
    | { last_created_at: string | null }
    | undefined;
  return row?.last_created_at ?? null;
}

export function setFetchWatermark(chatId: string, iso: string): void {
  db()
    .prepare(
      `INSERT INTO fetch_state (chat_id, last_created_at) VALUES (?, ?)
       ON CONFLICT(chat_id) DO UPDATE SET last_created_at = excluded.last_created_at`,
    )
    .run(chatId, iso);
}
