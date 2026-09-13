// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// TEMPORARY probe: does realtime newMessage delivery work against local
// Supabase? The per-test deadline is higher than the 30 seconds `flutter test`
// prescribes: the delivery path may take long under load (see the reasoning at
// the wait). Without this the harness would strike BEFORE our own check bites —
// with a message that explains nothing.
@Timeout(Duration(minutes: 3))
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'realtime_join_support.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('realtime newMessage reaches the recipient channel', () async {
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final String aId, bId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('supabase not reachable');
      return;
    }
    final s = const Uuid().v4().substring(0, 8);
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'a_$s'});
      await bob.from('profiles').insert({'id': bId, 'username': 'b_$s'});
      final chat = await alice.from('chats').insert({'name': 'rt_$s'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members').insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
      await alice.from('chat_members').insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

      final got = Completer<Map<String, dynamic>>();
      // The PRIVATE channel, exactly as the app subscribes to it
      // (`event_bus_service.dart`). The public twin `user:<id>` is gone with
      // 00080 — whoever goes on listening to it waits for an event nobody sends
      // any more and gets a timeout instead of a finding. `setAuth` is needed
      // because the RLS policy on `realtime.messages` checks the topic against
      // `auth.uid()`.
      bob.realtime.setAuth(bob.auth.currentSession!.accessToken);
      final ch = bob.channel(
        'p:user:$bId',
        opts: const RealtimeChannelConfig(private: true),
      );
      ch.onBroadcast(event: 'event', callback: (payload) {
        if (!got.isCompleted) got.complete(payload);
      });
      // WAIT for the join, do not hope for it for two seconds — see
      // `realtime_join_support.dart`.
      await awaitJoined(ch);

      // Up to four attempts — see `sendeBisEmpfangen`: if the first falls into
      // a realtime tenant that is just coming up cold, it never arrives, and
      // waiting longer does not help then.
      final angekommen = await sendUntilReceived(
        send: () => alice.from('messages').insert({
          'id': const Uuid().v4(), 'chat_id': chatId, 'sender_id': aId,
          'recipient_id': bId, 'encrypted_content': 'x',
        }),
        empfangen: got,
      );
      // ignore: avoid_print
      print('REALTIME_PAYLOAD: ${angekommen ? await got.future : "nichts"}');
      expect(angekommen, isTrue,
          reason: 'realtime delivered nothing even after four attempts');
      await bob.removeChannel(ch);
    } finally {
      if (chatId != null) {
        try { await alice.from('chats').delete().eq('id', chatId); } catch (_) {}
      }
      await alice.dispose();
      await bob.dispose();
    }
  });
}
