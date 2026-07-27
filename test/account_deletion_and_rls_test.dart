// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration tests against the LOCAL Supabase stack (self-skip when absent):
//
//  B4 / migration 00021: the messages INSERT policy must reject senders that
//  are not members of the target chat (previously any authenticated user
//  could spam-insert into foreign chats → push/unread DoS).
//
//  F1 / delete-account semantics: logging out deletes the account server-side.
//  This exercises the exact deletion order the `delete-account` Edge Function
//  performs (sent messages → profile [cascades chat_members + admin trigger]
//  → auth user [cascades own copies, tokens, pending]) and asserts nothing
//  is left behind and surviving chats stay intact.
//
//   flutter test test/account_deletion_and_rls_test.dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
  // Local demo service-role key (public knowledge, local stack only).
  const serviceKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

  test('00021: a non-member cannot insert messages into a foreign chat',
      () async {
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final mallory = SupabaseClient(url, anonKey);
    final String aId, bId, mId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
      mId = (await mallory.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    await alice.from('profiles').insert({'id': aId, 'username': 'a_$suffix'});
    await bob.from('profiles').insert({'id': bId, 'username': 'b_$suffix'});
    await mallory
        .from('profiles')
        .insert({'id': mId, 'username': 'm_$suffix'});

    final chat = await alice
        .from('chats')
        .insert({'name': 'rls_$suffix'})
        .select()
        .single();
    final chatId = chat['id'] as String;
    await alice
        .from('chat_members')
        .insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
    await alice
        .from('chat_members')
        .insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

    Map<String, dynamic> row(String senderId) => {
          'id': const Uuid().v4(),
          'chat_id': chatId,
          'sender_id': senderId,
          'recipient_id': bId,
          'encrypted_content': 'junk',
          'message_type': 'user',
        };

    // Member sender: allowed.
    await alice.from('messages').insert(row(aId));

    // Non-member sender targeting a legit member: must be rejected by RLS.
    await expectLater(
      mallory.from('messages').insert(row(mId)),
      throwsA(isA<PostgrestException>()),
      reason: 'sender is not a chat member — 00021 must block the insert',
    );

    await alice.auth.signOut();
    await bob.auth.signOut();
    await mallory.auth.signOut();
  });

  test('F1: server-side account deletion leaves nothing behind', () async {
    final alice = SupabaseClient(url, anonKey); // stays
    final leaver = SupabaseClient(url, anonKey); // account gets deleted
    final String aId, lId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      lId = (await leaver.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    await alice.from('profiles').insert({'id': aId, 'username': 'stay_$suffix'});
    await leaver
        .from('profiles')
        .insert({'id': lId, 'username': 'leave_$suffix'});

    // Shared chat created by the LEAVER (they are its admin) + a solo chat
    // where the leaver is the only member (must vanish entirely).
    final shared = await leaver
        .from('chats')
        .insert({'name': 'shared_$suffix'})
        .select()
        .single();
    final sharedId = shared['id'] as String;
    await leaver
        .from('chat_members')
        .insert({'chat_id': sharedId, 'user_id': lId, 'public_key': 'k'});
    await leaver
        .from('chat_members')
        .insert({'chat_id': sharedId, 'user_id': aId, 'public_key': 'k'});

    final solo = await leaver
        .from('chats')
        .insert({'name': 'solo_$suffix'})
        .select()
        .single();
    final soloId = solo['id'] as String;
    await leaver
        .from('chat_members')
        .insert({'chat_id': soloId, 'user_id': lId, 'public_key': 'k'});

    // Undelivered message from the leaver to alice + one from alice to the
    // leaver (the latter must be cascaded away with the auth user).
    await leaver.from('messages').insert({
      'id': const Uuid().v4(),
      'chat_id': sharedId,
      'sender_id': lId,
      'recipient_id': aId,
      'encrypted_content': 'from-leaver',
      'message_type': 'user',
    });
    await alice.from('messages').insert({
      'id': const Uuid().v4(),
      'chat_id': sharedId,
      'sender_id': aId,
      'recipient_id': lId,
      'encrypted_content': 'to-leaver',
      'message_type': 'user',
    });

    // --- the delete-account Edge Function's exact steps, via service role ---
    final admin = SupabaseClient(url, serviceKey);
    await admin.from('messages').delete().eq('sender_id', lId);
    await admin.from('profiles').delete().eq('id', lId);
    await admin.auth.admin.deleteUser(lId);

    // Nothing of the leaver may remain.
    expect(await admin.from('profiles').select().eq('id', lId), isEmpty);
    expect(
        await admin.from('chat_members').select().eq('user_id', lId), isEmpty);
    expect(
        await admin.from('messages').select().eq('sender_id', lId), isEmpty);
    expect(await admin.from('messages').select().eq('recipient_id', lId),
        isEmpty);
    expect(await admin.from('device_tokens').select().eq('user_id', lId),
        isEmpty);

    // The solo chat (leaver was sole member) is gone; the shared chat
    // survives with alice as remaining member and admin.
    expect(await admin.from('chats').select().eq('id', soloId), isEmpty);
    final sharedAfter =
        await admin.from('chats').select().eq('id', sharedId).single();
    expect(List<dynamic>.from(sharedAfter['admins'] as List), contains(aId));
    expect(List<dynamic>.from(sharedAfter['admins'] as List),
        isNot(contains(lId)));

    await alice.auth.signOut();
    await admin.auth.admin.deleteUser(aId).catchError((_) => null);
  });
}
