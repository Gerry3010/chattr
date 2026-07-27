// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Real Supabase Realtime backing for chattr_wait — the same broadcast
// channel the Flutter app itself listens on (verified against
// lib/core/events/event_bus_service.dart and
// supabase/migrations/00029_notification_payloads.sql), so this reuses the
// existing server-side trigger with zero backend changes:
//
//   channel: `user:<userId>`, broadcast event name: 'event'
//   payload (unwrapped): {"type":"newMessage","chat_id":...,"message_id":...,...}
//
// notify_members_new_message sends one broadcast per RECIPIENT row —
// recipient_id lives only in the topic string, not the payload — so
// subscribing to `user:<our own userId>` is exactly the filter we want.
//
// The mcp_server process is long-lived for the whole stdio session, so we
// keep ONE channel per userId open for the process lifetime (lazy-opened on
// first use) instead of reconnecting per tool call — cheaper and closes the
// "message arrives between subscribing and awaiting" race almost entirely
// (the remaining gap is covered by messages.ts calling fetchMessages()
// immediately before waiting, plus the safety-net tick below).

import { EventEmitter } from 'node:events';
import type { SupabaseClient, RealtimeChannel } from '@supabase/supabase-js';

const channels = new Map<string, RealtimeChannel>();
const emitter = new EventEmitter();
// Many chats can be waited on concurrently; each may have several listeners.
emitter.setMaxListeners(0);

interface NewMessagePayload {
  type: string;
  chat_id: string;
  message_id: string;
  sender_id: string | null;
}

function eventName(chatId: string): string {
  return `newMessage:${chatId}`;
}

/** Idempotent: opens the user's broadcast channel once per process, reused across calls. */
function ensureSubscribed(client: SupabaseClient, userId: string): void {
  if (channels.has(userId)) return;

  const channel = client
    .channel(`user:${userId}`)
    .on('broadcast', { event: 'event' }, (msg: { payload?: unknown }) => {
      const payload = msg.payload as NewMessagePayload | undefined;
      if (payload?.type === 'newMessage' && payload.chat_id) {
        emitter.emit(eventName(payload.chat_id));
      }
    })
    .subscribe();

  channels.set(userId, channel);
}

/**
 * Resolves as soon as a newMessage broadcast for `chatId` arrives, a 30s
 * safety-net tick fires (Realtime delivery isn't guaranteed across network
 * hiccups — this just prompts messages.ts to re-check via fetchMessages()),
 * or `timeoutMs` elapses. Never rejects.
 */
export function waitForNewMessage(client: SupabaseClient, userId: string, chatId: string, timeoutMs: number): Promise<void> {
  ensureSubscribed(client, userId);

  return new Promise((resolve) => {
    const name = eventName(chatId);
    let done = false;

    const finish = () => {
      if (done) return;
      done = true;
      emitter.off(name, onEvent);
      clearInterval(safetyNet);
      clearTimeout(deadline);
      resolve();
    };

    const onEvent = () => finish();
    emitter.once(name, onEvent);

    const safetyNet = setInterval(finish, 30_000);
    const deadline = setTimeout(finish, timeoutMs);
  });
}

/** Closes every open channel — call on process shutdown. */
export async function closeAll(): Promise<void> {
  for (const channel of channels.values()) {
    await channel.unsubscribe();
  }
  channels.clear();
}
