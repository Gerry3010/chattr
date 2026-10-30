// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration test for direct-chat dedup (ChatsRepository.findDirectChat).
// Bug #98: re-adding the same 1:1 partner (QR/manual ID) created a duplicate
// chat because createChat was called unconditionally. findDirectChat now finds
// an existing non-group chat with the pair so the caller can reuse it.
//
// Proves against the real DB: findDirectChat returns the existing 1:1, returns
// null for a stranger, and (crucially) the RLS-based query only sees the shared
// chat — a sender queries the PEER's chat_members rows, which RLS exposes only
// for chats the caller is also in.
//
// Requires local Supabase (`supabase start`); skips itself if unreachable.
//
//   flutter test test/dedupe_direct_chat_test.dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chattr/features/chats/chats_repository.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('findDirectChat: finds the existing 1:1, null for a stranger', () async {
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
    final aliceRepo = ChatsRepository(alice);
    final strangerId = const Uuid().v4();
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});

      // No chat yet → no direct chat with anyone.
      expect(await aliceRepo.findDirectChat(bId, aId), isNull,
          reason: 'before any chat, there is no direct chat to find');

      // Create the 1:1 (both members, non-group) — as the app does.
      final created = await aliceRepo.createChat([aId, bId], isGroup: false);
      chatId = created.id;

      // findDirectChat returns exactly that chat.
      expect(await aliceRepo.findDirectChat(bId, aId), chatId,
          reason: 'the existing 1:1 must be found so it is reused, not dupliated');

      // A stranger we share no chat with → null (so a real new chat is created).
      expect(await aliceRepo.findDirectChat(strangerId, aId), isNull,
          reason: 'no shared chat with a stranger → must create a fresh one');

      // Self → null (never a "direct chat with myself").
      expect(await aliceRepo.findDirectChat(aId, aId), isNull);

      // A GROUP chat with bob must NOT be mistaken for a direct chat.
      final group =
          await aliceRepo.createChat([aId, bId], isGroup: true, name: 'grp_$suffix');
      // Still returns the 1:1 (the non-group one), not the group.
      expect(await aliceRepo.findDirectChat(bId, aId), chatId,
          reason: 'is_group=true chats must be excluded from direct-chat lookup');
      await alice.from('chats').delete().eq('id', group.id);
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
