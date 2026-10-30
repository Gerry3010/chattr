// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The real path of a call signal against the local stack: a client calls
// `send_call_signal` (00085), the server forwards it onto the PEER's private
// bus, and the peer's app parses it as a CallSignalEvent — with the sender id
// the SERVER stamped, not one the caller chose. Plus the two refusals that
// matter: a stranger can't ring, and nobody reaches `chattr_send` (00084).
// Skips itself when Supabase isn't running.
@Timeout(Duration(minutes: 3))
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chattr/core/events/event_types.dart';

import 'realtime_join_support.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('Anruf-Signal erreicht den Kanal des Gegenübers, Fremde nicht',
      () async {
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final mallory = SupabaseClient(url, anonKey);
    final anon = SupabaseClient(url, anonKey);
    final String aId, bId, mId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
      mId = (await mallory.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('supabase not reachable');
      return;
    }
    final s = const Uuid().v4().substring(0, 6);
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'ca_$s'});
      await bob.from('profiles').insert({'id': bId, 'username': 'cb_$s'});
      await mallory.from('profiles').insert({'id': mId, 'username': 'cm_$s'});

      // The consented way to a 1:1: request + accept (00082).
      await alice.rpc<void>('send_chat_request', params: {'p_target': bId});
      chatId = await bob.rpc<String>('accept_chat_request',
          params: {'p_requester': aId});

      final got = Completer<Map<String, dynamic>>();
      bob.realtime.setAuth(bob.auth.currentSession!.accessToken);
      final ch = bob.channel('p:user:$bId',
          opts: const RealtimeChannelConfig(private: true));
      ch.onBroadcast(event: 'event', callback: (payload) {
        final inner = (payload['payload'] ?? payload) as Map<String, dynamic>;
        if (inner['type'] == 'callSignal' && !got.isCompleted) {
          got.complete(inner);
        }
      });
      await awaitJoined(ch);

      final signalId = const Uuid().v4();
      final angekommen = await sendUntilReceived(
        send: () => alice.rpc<void>('send_call_signal', params: {
          'p_chat_id': chatId,
          'p_to': bId,
          'p_signal_id': signalId,
          'p_envelope': '{"v":4,"opaque":true}',
        }),
        empfangen: got,
      );
      expect(angekommen, isTrue, reason: 'call signal never arrived');

      final event = BusEvent.fromJson(await got.future);
      expect(event, isA<CallSignalEvent>());
      final e = event as CallSignalEvent;
      expect(e.senderId, aId, reason: 'sender must be stamped by the server');
      expect(e.chatId, chatId);
      expect(e.signalId, signalId);
      expect(e.envelope, '{"v":4,"opaque":true}');

      // A stranger is not a member of the chat: refused.
      await expectLater(
        mallory.rpc<void>('send_call_signal', params: {
          'p_chat_id': chatId,
          'p_to': bId,
          'p_signal_id': const Uuid().v4(),
          'p_envelope': 'x',
        }),
        throwsA(isA<PostgrestException>()),
      );

      // And the raw broadcast door is shut for everybody (00084).
      await expectLater(
        anon.rpc<void>('chattr_send', params: {
          'payload': {'type': 'chatDeleted', 'chat_id': chatId},
          'event': 'event',
          'topic': 'user:$bId',
        }),
        throwsA(isA<PostgrestException>()),
      );
      await expectLater(
        mallory.rpc<void>('chattr_send', params: {
          'payload': {'type': 'chatDeleted', 'chat_id': chatId},
          'event': 'event',
          'topic': 'user:$bId',
        }),
        throwsA(isA<PostgrestException>()),
      );

      await bob.removeChannel(ch);
    } finally {
      if (chatId != null) {
        try {
          await alice.from('chats').delete().eq('id', chatId);
        } catch (_) {}
      }
      await alice.dispose();
      await bob.dispose();
      await mallory.dispose();
      await anon.dispose();
    }
  });
}
