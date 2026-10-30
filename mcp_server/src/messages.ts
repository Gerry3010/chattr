// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Send/fetch/history/wait. Mirrors messages_repository.dart's schema
// (composite PK id+recipient_id, one row per recipient) and read-marking
// RPCs; encrypt/decrypt goes through crypto_port.ts (byte-identical wire
// format to the Flutter client).

import type { SupabaseClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import {
  encryptForAllMembers,
  decryptEnvelopeFull,
  signingBytes,
  signWithIdentity,
  type MessageContext,
} from './crypto_port.js';
import { ensureIdentityPublished } from './identity.js';
import { getOtherMemberKeys, requireLocalKeyPair } from './chats.js';
import { getUsername } from './supabase.js';
import { saveMessage, listMessages, getFetchWatermark, setFetchWatermark, type StoredMessage } from './state.js';
import { waitForNewMessage } from './realtime.js';

/**
 * True when the plaintext is summary machinery (the app's features/summary/):
 * a `_chattr_summarize` request or a `_chattr_summary` reply. Such messages
 * are sent with message_type='summary' so the server's push trigger skips
 * them — the server cannot tell machinery from conversation by ciphertext
 * alone, the sender has to say so (migration 00068). A message that merely
 * TALKS about the markers is not machinery: it has to BE the JSON envelope.
 */
function isSummaryEnvelope(text: string): boolean {
  if (!text.includes('_chattr_summarize') && !text.includes('_chattr_summary')) return false;
  try {
    const json: unknown = JSON.parse(text);
    if (typeof json !== 'object' || json === null) return false;
    const obj = json as Record<string, unknown>;
    return obj['_chattr_summarize'] != null || obj['_chattr_summary'] != null;
  } catch {
    return false;
  }
}

export async function sendMessage(
  client: SupabaseClient,
  userId: string,
  chatId: string,
  text: string,
): Promise<{ messageId: string; recipientCount: number }> {
  const memberKeys = await getOtherMemberKeys(client, chatId, userId);
  if (memberKeys.length === 0) {
    throw new Error('No other members with a registered key in this chat yet — nothing to send to.');
  }

  const keyMap: Record<string, string> = {};
  for (const m of memberKeys) keyMap[m.userId] = m.publicKey;

  // v4 envelope: AAD-bound to (chat, sender, message) and identity-signed
  // (audit H1/M3) — the id is minted before encryption so it can be covered.
  const messageId = randomUUID();
  const context: MessageContext = { chatId, senderId: userId, messageId };
  let signature: string | undefined;
  try {
    const identity = await ensureIdentityPublished(client, userId);
    signature = await signWithIdentity(identity, signingBytes(context, text));
  } catch {
    // warn-only model: an unsigned message stays sendable
  }
  const encryptedForRecipients = await encryptForAllMembers(text, keyMap, context, signature);

  const createdAt = new Date().toISOString();
  const summary = isSummaryEnvelope(text);
  const rows = Object.entries(encryptedForRecipients).map(([recipientId, encryptedContent]) => ({
    id: messageId,
    chat_id: chatId,
    sender_id: userId,
    recipient_id: recipientId,
    encrypted_content: encryptedContent,
    created_at: createdAt,
    ...(summary ? { message_type: 'summary' } : {}),
  }));

  let { error } = await client.from('messages').insert(rows);
  if (error && summary && error.message.includes('message_type')) {
    // Backend predates migration 00068 ('summary' fails the CHECK constraint).
    // Degrade to a plain user message: the reply still arrives, the requester
    // just also gets a push — strictly better than the summary not arriving.
    ({ error } = await client
      .from('messages')
      .insert(rows.map(({ message_type: _, ...rest }) => rest)));
  }
  if (error) throw new Error(`Failed to send message: ${error.message}`);

  // Sender keeps its own plaintext copy locally — mirrors the app (which
  // never sends itself an encrypted copy either; memberKeys.remove(senderId)).
  const stored: StoredMessage = {
    messageId,
    chatId,
    senderId: userId,
    senderName: null,
    direction: 'out',
    createdAt,
    plaintext: text,
  };
  saveMessage(stored);

  return { messageId, recipientCount: rows.length };
}

export interface FetchedMessage {
  messageId: string;
  senderId: string | null;
  senderName: string | null;
  createdAt: string;
  text: string;
}

const usernameCache = new Map<string, string | null>();
async function resolveUsername(client: SupabaseClient, userId: string): Promise<string | null> {
  if (usernameCache.has(userId)) return usernameCache.get(userId)!;
  const name = await getUsername(userId);
  usernameCache.set(userId, name);
  return name;
}

/**
 * Fetches new messages for this chat, decrypts them, persists to the local
 * store, and clears server ciphertext (mark_message_read) — matching the
 * app's fetch-and-clear model. Returns the newly fetched messages
 * (chronological).
 */
export async function fetchMessages(
  client: SupabaseClient,
  userId: string,
  chatId: string,
): Promise<FetchedMessage[]> {
  const pair = requireLocalKeyPair(chatId);
  const since = getFetchWatermark(chatId);

  let query = client
    .from('messages')
    .select('id, sender_id, encrypted_content, created_at')
    .eq('chat_id', chatId)
    .eq('recipient_id', userId)
    .not('encrypted_content', 'is', null);
  if (since) query = query.gt('created_at', since);

  const { data, error } = await query.order('created_at', { ascending: true });
  if (error) throw new Error(`Failed to fetch messages: ${error.message}`);

  const out: FetchedMessage[] = [];
  let latestCreatedAt = since;

  for (const row of data ?? []) {
    const content = row.encrypted_content as string | null;
    if (!content) continue; // already cleared (e.g. re-fetched after a prior read)

    let plaintext: string;
    try {
      // v4 envelopes are AAD-bound; system messages use the 'system' sender.
      const decrypted = await decryptEnvelopeFull(content, pair, {
        chatId,
        senderId: (row.sender_id as string | null) ?? 'system',
        messageId: row.id as string,
      });
      // A shot (v6) may be opened once, by a person (CHAT-41). Stored here it
      // would sit in store.sqlite with its attachment key and come back on
      // every chattr_history. The agent gets a marker, never the content.
      plaintext = decrypted.version === 6 ? SHOT_MARKER : decrypted.plaintext;
    } catch (e) {
      // Skip messages we can't decrypt (wrong/rotated key) rather than aborting the whole fetch.
      continue;
    }

    const senderId = row.sender_id as string | null;
    const senderName = senderId ? await resolveUsername(client, senderId) : null;
    const createdAt = row.created_at as string;

    saveMessage({
      messageId: row.id as string,
      chatId,
      senderId,
      senderName,
      direction: 'in',
      createdAt,
      plaintext,
    });

    // mark_message_read clears server ciphertext — same call the app makes on display.
    await client.rpc('mark_message_read', { p_message_id: row.id, p_chat_id: chatId });

    out.push({ messageId: row.id as string, senderId, senderName, createdAt, text: plaintext });
    // created_at is the SENDER's to set (CHAT-41): one message dated 2099
    // would move the watermark past every real message to come and leave the
    // agent deaf in this chat. Never let it run ahead of the clock.
    const clamped = clampToNow(createdAt);
    if (!latestCreatedAt || clamped > latestCreatedAt) latestCreatedAt = clamped;
  }

  if (latestCreatedAt) setFetchWatermark(chatId, latestCreatedAt);
  return out;
}

/** What the agent sees instead of a view-once shot. */
export const SHOT_MARKER = '[Shot: only viewable once, in the app]';

/** [iso], or now if [iso] lies more than five minutes in the future. */
export function clampToNow(iso: string, now: Date = new Date()): string {
  const t = Date.parse(iso);
  const limit = now.getTime() + 5 * 60 * 1000;
  return Number.isFinite(t) && t <= limit ? iso : now.toISOString();
}

export function getHistory(chatId: string, limit: number): StoredMessage[] {
  return listMessages(chatId, limit);
}

/**
 * Waits for new messages via the same Realtime broadcast channel the
 * Flutter app listens on (`user:<userId>`, event 'event',
 * {"type":"newMessage",...} — see realtime.ts) instead of polling. Checks
 * immediately first (catches anything that arrived before this call, or in
 * the small gap before a fresh subscription is live), then blocks on the
 * broadcast event — with a 30s safety-net re-check in case delivery is ever
 * missed — until a message shows up or timeoutS elapses.
 */
export async function waitForMessages(
  client: SupabaseClient,
  userId: string,
  chatId: string,
  timeoutS: number,
): Promise<FetchedMessage[]> {
  const deadline = Date.now() + timeoutS * 1000;
  for (;;) {
    const found = await fetchMessages(client, userId, chatId);
    if (found.length > 0) return found;
    const remaining = deadline - Date.now();
    if (remaining <= 0) return [];
    await waitForNewMessage(client, userId, chatId, remaining);
  }
}
