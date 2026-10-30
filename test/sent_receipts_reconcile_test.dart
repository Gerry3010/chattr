// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration test for the sender-side read-receipt BACKFILL (migration 00042
// + MessagesRepository.fetchSentMessageStatus). The bug: receipts reach the
// sender only via the realtime broadcast, and 00010 dropped the sender SELECT
// policy — so a sender whose client was closed can neither see the broadcast
// nor query its own sent rows, and the ticks stay stuck forever.
//
// This proves both halves against the real DB:
//   * a plain sender SELECT of its sent row returns NOTHING (RLS blocks it) —
//     the reason a backfill is even needed;
//   * the SECURITY DEFINER RPC returns the received_at/read_at the recipient
//     set, and the `since` watermark bounds re-fetches.
//
// Requires local Supabase with migrations applied (`supabase start`); skips
// itself if unreachable. No native crypto — dummy ciphertext, status only.
//
//   flutter test test/sent_receipts_reconcile_test.dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chattr/features/messages/messages_repository.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('sender backfill: RLS hides own sent row, RPC surfaces its status',
      () async {
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final String aId, bId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    final aliceRepo = MessagesRepository(alice);
    final bobRepo = MessagesRepository(bob);
    final msgId = const Uuid().v4();
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});
      final chat = await alice
          .from('chats')
          .insert({'name': 'receipts_$suffix'})
          .select()
          .single();
      chatId = chat['id'] as String;
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

      // Alice sends one message to Bob (the per-recipient row for Bob).
      await alice.from('messages').insert({
        'id': msgId,
        'chat_id': chatId,
        'sender_id': aId,
        'recipient_id': bId,
        'encrypted_content': 'ciphertext',
      });

      // Before any receipt, the RPC yields no read/received status yet.
      final beforeAny = await aliceRepo.fetchSentMessageStatus();
      final beforeRow =
          beforeAny.where((r) => r['id'] == msgId).toList();
      expect(beforeRow, isEmpty,
          reason: 'no received_at/read_at set yet → RPC filters it out');

      // Bob (recipient, "comes online") marks the message received, then read.
      await bobRepo.markAsReceived(chatId, msgId, bId);
      await bobRepo.markAsRead(chatId, msgId, bId);

      // THE BUG: Alice (the sender) cannot see her own sent row via a normal
      // SELECT — 00010 left only `recipient_id = auth.uid()`.
      final direct = await alice
          .from('messages')
          .select('received_at, read_at')
          .eq('id', msgId);
      expect(direct, isEmpty,
          reason: 'sender SELECT of own sent row must be blocked by RLS');

      // THE FIX: the SECURITY DEFINER RPC surfaces the status Bob just set.
      final status = await aliceRepo.fetchSentMessageStatus();
      final row = status.firstWhere((r) => r['id'] == msgId,
          orElse: () => throw StateError('sent-status row not returned'));
      expect(row['recipient_id'], bId);
      expect(row['received_at'], isNotNull,
          reason: 'delivered timestamp must reconcile to the sender');
      expect(row['read_at'], isNotNull,
          reason: 'read timestamp must reconcile to the sender');

      // Watermark: a `since` in the future returns nothing (no needless refetch).
      final future = await aliceRepo.fetchSentMessageStatus(
        since: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      expect(future.where((r) => r['id'] == msgId), isEmpty,
          reason: 'since-watermark past the row must exclude it');
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } finally {
      if (chatId != null) {
        try {
          await alice.from('chats').delete().eq('id', chatId);
        } catch (_) {}
      }
      await alice.dispose();
      await bob.dispose();
    }
  });
}
