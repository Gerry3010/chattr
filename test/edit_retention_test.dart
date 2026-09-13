// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration test against the LOCAL Supabase stack (self-skips when absent)
// for migration 00070.
//
// Chattr's public promise is "delivered = deleted": the moment a recipient has
// fetched a message, the server drops the ciphertext. Editing broke that
// silently. `mark_message_received()` cleared only while `received_at IS NULL`,
// but an edit writes fresh ciphertext into a row that was already delivered —
// so the clear never fired again and the new text stayed on the server
// forever. Found on prod with 17 such rows, every single one edited.
//
// The client was never at fault: it re-fetches, decrypts, persists locally and
// then calls markAsReceived precisely to re-clear. That second call was what
// the server rejected.
//
//   flutter test test/edit_retention_test.dart
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

  test('00070: an edit after delivery can be cleared again', () async {
    final sender = SupabaseClient(url, anonKey);
    final recipient = SupabaseClient(url, anonKey);
    final String sId, rId;
    try {
      sId = (await sender.auth.signInAnonymously()).user!.id;
      rId = (await recipient.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('local Supabase not usable: $e');
      return;
    }

    final s = const Uuid().v4().substring(0, 8);
    try {
      await sender.from('profiles').insert({'id': sId, 'username': 'snd_$s'});
      await recipient
          .from('profiles')
          .insert({'id': rId, 'username': 'rcv_$s'});
      final chat = await sender
          .from('chats')
          .insert({'name': 'edit_$s'})
          .select()
          .single();
      final chatId = chat['id'] as String;
      for (final u in [sId, rId]) {
        await sender.from('chat_members').insert(
            {'chat_id': chatId, 'user_id': u, 'public_key': 'k'});
      }

      final msgId = const Uuid().v4();
      await sender.from('messages').insert({
        'id': msgId,
        'chat_id': chatId,
        'sender_id': sId,
        'recipient_id': rId,
        'encrypted_content': 'ORIGINAL',
      });

      // ── 1) Normal delivery still clears, as before ────────────────────────
      await recipient.rpc('mark_message_received',
          params: {'p_message_id': msgId, 'p_chat_id': chatId});
      var row = await recipient
          .from('messages')
          .select('encrypted_content, received_at')
          .eq('id', msgId)
          .single();
      expect(row['encrypted_content'], '',
          reason: 'first delivery must clear the ciphertext');
      expect(row['received_at'], isNotNull);
      final firstDelivery = row['received_at'] as String;

      // ── 2) The sender edits — fresh ciphertext lands in a delivered row ───
      // Through `edit_message`, exactly like the app: a direct UPDATE silently
      // matches 0 rows, because its WHERE clause is subject to the
      // recipient-only SELECT policy (documented in messages_repository).
      final touched = await sender.rpc<int>('edit_message', params: {
        'p_message_id': msgId,
        'p_chat_id': chatId,
        'p_contents': {rId: 'EDITED'},
      });
      expect(touched, 1, reason: 'the edit must reach the recipient row');
      row = await recipient
          .from('messages')
          .select('encrypted_content')
          .eq('id', msgId)
          .single();
      expect(row['encrypted_content'], 'EDITED',
          reason: 'precondition: the edit really is on the server');

      // ── 3) …and the recipient can clear it again. THIS is the fix. ────────
      // Before 00070 this call raised "Message not found or already received"
      // and the edited ciphertext stayed on the server for good.
      await recipient.rpc('mark_message_received',
          params: {'p_message_id': msgId, 'p_chat_id': chatId});
      row = await recipient
          .from('messages')
          .select('encrypted_content, received_at')
          .eq('id', msgId)
          .single();
      expect(row['encrypted_content'], '',
          reason: 'the edited ciphertext must be cleared too');

      // ── 4) The delivery timestamp must NOT move ───────────────────────────
      // An edit is not a new delivery; moving it would jump the sender's
      // "delivered" tick to a later time than the message actually arrived.
      expect(
        DateTime.parse(row['received_at'] as String)
            .isAtSameMomentAs(DateTime.parse(firstDelivery)),
        isTrue,
        reason: 'the first delivery time must survive the re-clear',
      );

      // ── 5) A third call on an emptied row still refuses ───────────────────
      // Unchanged behaviour — the guard against pointless/duplicate calls.
      await expectLater(
        recipient.rpc('mark_message_received',
            params: {'p_message_id': msgId, 'p_chat_id': chatId}),
        throwsA(isA<PostgrestException>()),
      );

      // ── 6) Not even the sender may clear the recipient's row ──────────────
      // The `recipient_id = auth.uid()` check is what makes relaxing the
      // condition safe at all — otherwise anyone could wipe a row that the
      // recipient has not fetched yet, and the message would be lost.
      await sender.rpc<int>('edit_message', params: {
        'p_message_id': msgId,
        'p_chat_id': chatId,
        'p_contents': {rId: 'EDITED-AGAIN'},
      });
      await expectLater(
        sender.rpc('mark_message_received',
            params: {'p_message_id': msgId, 'p_chat_id': chatId}),
        throwsA(isA<PostgrestException>()),
        reason: 'only the recipient of the row may clear it',
      );
    } finally {
      await sender.auth.signOut();
      await recipient.auth.signOut();
    }
  });
}
