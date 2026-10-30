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
//  → auth user [cascades own copies, tokens, pending] → images in storage)
//  and asserts nothing is left behind and surviving chats stay intact —
//  including their group picture, which is the one thing here that belongs to
//  people who did NOT delete anything.
//
//   flutter test test/account_deletion_and_rls_test.dart
@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

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

    // Pictures: the leaver's own, the solo chat's (dies with the account) and
    // the shared chat's (must survive — alice is still in it).
    final admin = SupabaseClient(url, serviceKey);
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
    Future<void> put(String bucket, String path) => admin.storage
        .from(bucket)
        .uploadBinary(path, png, fileOptions: const FileOptions(upsert: true));
    await put('avatars', '$lId/avatar.jpg');
    await put('group-avatars', '$soloId/avatar.jpg');
    await put('group-avatars', '$sharedId/avatar.jpg');

    // --- the delete-account Edge Function's exact steps, via service role ---
    // Step 0 first: chat_members is what the profile delete takes away, so the
    // list of "which chats was this account in" has to be read before it.
    final memberChatIds = (await admin
            .from('chat_members')
            .select('chat_id')
            .eq('user_id', lId))
        .map((m) => m['chat_id'] as String)
        .toList();

    await admin.from('messages').delete().eq('sender_id', lId);
    await admin.from('profiles').delete().eq('id', lId);
    await admin.auth.admin.deleteUser(lId);

    // Images last. Ask for the SURVIVORS, not the dead ones: a failed read
    // then deletes nothing instead of everything.
    Future<void> purge(String bucket, String folder) async {
      final entries = await admin.storage.from(bucket).list(path: folder);
      final paths = entries
          .where((e) => e.id != null && e.name != '.emptyFolderPlaceholder')
          .map((e) => '$folder/${e.name}')
          .toList();
      if (paths.isNotEmpty) await admin.storage.from(bucket).remove(paths);
    }

    await purge('avatars', lId);
    final alive = (await admin.from('chats').select('id').inFilter(
              'id',
              memberChatIds,
            ))
        .map((c) => c['id'] as String)
        .toSet();
    for (final chatId in memberChatIds.where((id) => !alive.contains(id))) {
      await purge('group-avatars', chatId);
    }

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

    // The account's own picture is gone, and so is the picture of the chat
    // that died with it — until 00075 lands, a leftover here stays fetchable
    // by anyone with the anon key.
    expect(
      await admin.storage.from('avatars').list(path: lId),
      isEmpty,
      reason: 'the deleted account still has a picture on the server',
    );
    expect(
      await admin.storage.from('group-avatars').list(path: soloId),
      isEmpty,
      reason: 'the chat is gone, its picture is not',
    );

    // And the chat that survives keeps its face. This is the assertion that
    // guards other people's data: the bytes cannot be brought back.
    expect(
      (await admin.storage.from('group-avatars').list(path: sharedId))
          .map((e) => e.name),
      contains('avatar.jpg'),
      reason: 'a living group must not lose its picture because someone left',
    );

    await admin.storage.from('group-avatars').remove(['$sharedId/avatar.jpg']);
    await alice.auth.signOut();
    await admin.auth.admin.deleteUser(aId).catchError((_) => null);
  });
}
