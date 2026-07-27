// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// TEMPORARY probe: does realtime newMessage delivery work against local Supabase?
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
      final ch = bob.channel('user:$bId');
      ch.onBroadcast(event: 'event', callback: (payload) {
        if (!got.isCompleted) got.complete(payload);
      }).subscribe();

      // give the subscription a moment to establish
      await Future.delayed(const Duration(seconds: 2));

      final msgId = const Uuid().v4();
      await alice.from('messages').insert({
        'id': msgId, 'chat_id': chatId, 'sender_id': aId,
        'recipient_id': bId, 'encrypted_content': 'x',
      });

      final payload = await got.future.timeout(const Duration(seconds: 8),
          onTimeout: () => {'__timeout__': true});
      // ignore: avoid_print
      print('REALTIME_PAYLOAD: $payload');
      expect(payload.containsKey('__timeout__'), isFalse,
          reason: 'expected a realtime event within 8s');
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
