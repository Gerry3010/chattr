// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration test for the app-resume fix: EventBusService.reconnect() must
// rebuild the (possibly OS-dropped) realtime channel so broadcasts keep
// reaching the in-process event stream after returning from the background.
//
// Requires local Supabase (`supabase start`); skips itself if unreachable.
//
//   flutter test test/event_bus_reconnect_test.dart
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/core/events/event_types.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('reconnect() keeps realtime events flowing to the event stream',
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

    final s = const Uuid().v4().substring(0, 8);
    final bus = EventBusService(bob, bId);
    final received = <BusEvent>[];
    final sub = bus.eventStream.listen(received.add);
    // #121: the bus fires onResubscribed after re-joining the channel (the same
    // code path an in-place auto-reconnect hits) so controllers can catch up.
    final resubscribed = <void>[];
    final resubSub = bus.onResubscribed.listen(resubscribed.add);
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'a_$s'});
      await bob.from('profiles').insert({'id': bId, 'username': 'b_$s'});
      final chat =
          await alice.from('chats').insert({'name': 'rc_$s'}).select().single();
      chatId = chat['id'] as String;
      await alice
          .from('chat_members')
          .insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
      await alice
          .from('chat_members')
          .insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

      Future<void> send() => alice.from('messages').insert({
            'id': const Uuid().v4(),
            'chat_id': chatId,
            'sender_id': aId,
            'recipient_id': bId,
            'encrypted_content': 'x',
          });

      Future<bool> waitForCount(int target) async {
        for (var i = 0; i < 40; i++) {
          if (received.length >= target) return true;
          await Future.delayed(const Duration(milliseconds: 250));
        }
        return false;
      }

      bus.subscribe();
      await Future.delayed(const Duration(seconds: 2)); // let it establish

      await send();
      expect(await waitForCount(1), isTrue,
          reason: 'expected a realtime event before reconnect');
      final before = received.length;

      // Simulate the resume path: rebuild the channel.
      await bus.reconnect();
      await Future.delayed(const Duration(seconds: 2)); // let it re-establish

      await send();
      expect(await waitForCount(before + 1), isTrue,
          reason: 'events must keep flowing after reconnect()');

      // The re-subscribe must have fired the catch-up signal (controllers hang
      // their missed-broadcast resync off this).
      expect(resubscribed, isNotEmpty,
          reason: 'reconnect() must emit onResubscribed after re-joining');
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } finally {
      await resubSub.cancel();
      await sub.cancel();
      await bus.dispose();
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
