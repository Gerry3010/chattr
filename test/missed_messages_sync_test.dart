// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration test for offline / missed-message resync against the local
// Supabase stack — the exact bug class found while live-testing:
//   * fetchInitial(since:) must use a UTC-correct comparison (a local `since`
//     used to be misread as UTC, dropping every message within the tz offset).
//   * resuming from a watermark must return only newer messages, never skip.
//
// Requires local Supabase (`supabase start`); skips itself if unreachable.
// No native crypto needed — we insert dummy ciphertext and test the fetch
// filter, not decryption.
//
//   flutter test test/missed_messages_sync_test.dart
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

  test('missed-message resync: since/watermark returns only newer messages',
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
    final bobRepo = MessagesRepository(bob);
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});
      final chat =
          await alice.from('chats').insert({'name': 'sync_$suffix'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

      Future<void> send(String body) => alice.from('messages').insert({
            'id': const Uuid().v4(),
            'chat_id': chatId,
            'sender_id': aId,
            'recipient_id': bId,
            'encrypted_content': body,
          });

      // Bob is "offline": Alice sends two messages (spaced so updated_at differs).
      await send('ct-1');
      await Future.delayed(const Duration(milliseconds: 400));
      await send('ct-2');

      // Full sync (no watermark) returns both of Bob's rows.
      final firstSync = await bobRepo.fetchInitial(chatId, bId);
      expect(firstSync.length, 2,
          reason: 'a from-scratch sync must return all of the recipient\'s rows');

      // Compute the watermark exactly like the controller does.
      DateTime? watermark;
      for (final m in firstSync) {
        final ts = m.updatedAt ?? m.createdAt;
        if (watermark == null || ts.isAfter(watermark)) watermark = ts;
      }
      expect(watermark, isNotNull);

      // A third message arrives after the watermark.
      await Future.delayed(const Duration(milliseconds: 400));
      await send('ct-3');

      // Resume from the watermark — passed as a LOCAL DateTime on purpose: this
      // is the regression guard for the timezone bug. If fetchInitial does not
      // normalize to UTC, a local `since` on a non-UTC machine is read as UTC
      // and the just-sent message (only ~0.4s newer) falls before the shifted
      // watermark and is dropped. With the fix, exactly the new message returns.
      final resumed = await bobRepo.fetchInitial(
        chatId,
        bId,
        since: watermark!.toLocal(),
      );
      expect(resumed.length, 1,
          reason: 'resuming from the watermark must return only newer messages');

      // And resuming from "now" returns nothing (no spurious re-delivery).
      final empty = await bobRepo.fetchInitial(
        chatId,
        bId,
        since: DateTime.now().toUtc().add(const Duration(seconds: 1)),
      );
      expect(empty, isEmpty);
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
