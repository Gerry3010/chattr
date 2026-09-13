// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// End-to-end integration test: two users (two Supabase clients) against the local
// stack exercise the full encrypted-chat flow with real auth + RLS + triggers and
// the post-quantum hybrid crypto.
//
// Requires:
//   - local Supabase running (`supabase start`)
//   - the native crypto lib built (`./native/build.sh`)
// Both are checked at runtime; the test skips itself if either is missing.
//
//   flutter test test/e2e_two_users_test.dart
// The per-test deadline is higher than the 30 seconds `flutter test` prescribes:
// the delivery path may take long under load (see the reasoning at the wait).
// Without this the harness would strike BEFORE our own check bites — with a
// message that explains nothing.
@Timeout(Duration(minutes: 3))
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'realtime_join_support.dart';

import 'package:chattr/core/crypto/ml_kem_ffi.dart' show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/chats/chat_member_keys_repository.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';

  final libExists = File(libPath).existsSync();

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('two users: register → chat → join → encrypted send → decrypt (PQC)',
      () async {
    if (!libExists) {
      markTestSkipped('native crypto lib not built ($libPath)');
      return;
    }

    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);

    // 1) Both register (anonymous auth → distinct user ids).
    final String aId, bId;
    try {
      final ra = await alice.auth.signInAnonymously();
      final rb = await bob.auth.signInAnonymously();
      aId = ra.user!.id;
      bId = rb.user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    String? chatId;
    try {
      // 2) Profiles.
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});

      // 3) Per-chat hybrid key pairs (X25519 + ML-KEM-768).
      final aKeys = await ChatKeyPairManager.generateDetachedKeyPair();
      final bKeys = await ChatKeyPairManager.generateDetachedKeyPair();

      // 4) Alice creates a chat (the creator trigger makes her the admin) and
      //    adds herself as a member with her public key.
      final chat =
          await alice.from('chats').insert({'name': 'e2e_$suffix'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members').insert(
          {'chat_id': chatId, 'user_id': aId, 'public_key': aKeys.publicKey});

      // 5) Bob requests to join; Alice (admin) approves.
      await bob.from('pending_chat_members').insert(
          {'chat_id': chatId, 'user_id': bId, 'public_key': bKeys.publicKey});
      await alice
          .from('pending_chat_members')
          .delete()
          .eq('chat_id', chatId)
          .eq('user_id', bId);
      await alice.from('chat_members').insert(
          {'chat_id': chatId, 'user_id': bId, 'public_key': bKeys.publicKey});

      // 6) Alice fetches the member public keys and encrypts a message for all.
      final members = await alice
          .from('chat_members')
          .select('user_id, public_key')
          .eq('chat_id', chatId) as List<dynamic>;
      final memberKeys = <String, String>{
        for (final m in members)
          (m as Map)['user_id'] as String: m['public_key'] as String,
      };
      expect(memberKeys.keys.toSet(), {aId, bId});

      final svc =
          MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));
      const plaintext = 'Hallo Bob — Post-Quantum E2E! 🔐🎉';
      final encrypted = await svc.encryptForAllMembers(plaintext, memberKeys);

      // 7) Alice inserts one encrypted row per recipient.
      final msgId = const Uuid().v4();
      await alice.from('messages').insert([
        for (final e in encrypted.entries)
          {
            'id': msgId,
            'chat_id': chatId,
            'sender_id': aId,
            'recipient_id': e.key,
            'encrypted_content': e.value,
          }
      ]);

      // 8) Bob fetches HIS row and decrypts it with his private key.
      final bobRow = await bob
          .from('messages')
          .select('encrypted_content')
          .eq('id', msgId)
          .eq('recipient_id', bId)
          .single();
      final decrypted = await svc.decryptMessage(
          bobRow['encrypted_content'] as String, bKeys.privateKey);
      expect(decrypted, plaintext, reason: 'Bob must decrypt to the original');

      // 9) RLS: Alice (sender) must NOT be able to read Bob's per-recipient row.
      final aliceSeesBobRow = await alice
          .from('messages')
          .select('recipient_id')
          .eq('id', msgId)
          .eq('recipient_id', bId) as List<dynamic>;
      expect(aliceSeesBobRow, isEmpty,
          reason: 'recipient-only RLS must hide Bob\'s row from Alice');
    } finally {
      // Cleanup: deleting the chat cascades to members/messages/pending.
      if (chatId != null) {
        try {
          await alice.from('chats').delete().eq('id', chatId);
        } catch (_) {}
      }
      await alice.dispose();
      await bob.dispose();
    }
  });

  test('realtime: recipient receives a newMessage event on user:<id>', () async {
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
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});
      final chat =
          await alice.from('chats').insert({'name': 'rt_$suffix'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': aId, 'public_key': 'k'});
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': bId, 'public_key': 'k'});

      // Bob subscribes to his user channel (the single "main bus" channel).
      final received = Completer<Map<String, dynamic>>();
      // The PRIVATE channel, exactly as the app subscribes to it
      // (`event_bus_service.dart`). The public twin `user:<id>` is gone with
      // 00080 — whoever goes on listening to it waits for an event nobody sends
      // any more and gets a timeout instead of a finding. `setAuth` is needed
      // because the RLS policy on `realtime.messages` checks the topic against
      // `auth.uid()`.
      bob.realtime.setAuth(bob.auth.currentSession!.accessToken);
      final channel = bob.channel(
        'p:user:$bId',
        opts: const RealtimeChannelConfig(private: true),
      );
      channel.onBroadcast(
        event: 'event',
        callback: (payload) {
          if (!received.isCompleted) received.complete(payload);
        },
      );
      // WAIT for the join, do not hope for it for two seconds — see
      // `realtime_join_support.dart`.
      await awaitJoined(channel);

      // Alice sends a message to Bob → notify_members_new_message broadcasts
      // it. Up to four attempts — see `sendeBisEmpfangen`. That is why EVERY
      // sent id is remembered: if the first attempt's broadcast arrived late, a
      // comparison against only the last id would be a false negative.
      final sent = <String>[];
      final angekommen = await sendUntilReceived(
        send: () {
          final id = const Uuid().v4();
          sent.add(id);
          return alice.from('messages').insert({
            'id': id,
            'chat_id': chatId,
            'sender_id': aId,
            'recipient_id': bId,
            'encrypted_content': 'ciphertext',
          });
        },
        empfangen: received,
      );
      expect(angekommen, isTrue,
          reason: 'realtime delivered nothing even after four attempts');
      final payload = await received.future;
      final event = (payload['payload'] ?? payload) as Map<String, dynamic>;
      expect(event['type'], 'newMessage');
      expect(sent, contains(event['message_id']));
      expect(event['chat_id'], chatId);

      await bob.removeChannel(channel);
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

  test('forward secrecy: a removed member cannot read later messages', () async {
    if (!libExists) {
      markTestSkipped('native crypto lib not built ($libPath)');
      return;
    }

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
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});
      final aKeys = await ChatKeyPairManager.generateDetachedKeyPair();
      final bKeys = await ChatKeyPairManager.generateDetachedKeyPair();

      // Alice creates the chat, both become members.
      final chat =
          await alice.from('chats').insert({'name': 'fs_$suffix'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members').insert(
          {'chat_id': chatId, 'user_id': aId, 'public_key': aKeys.publicKey});
      await bob.from('pending_chat_members').insert(
          {'chat_id': chatId, 'user_id': bId, 'public_key': bKeys.publicKey});
      await alice
          .from('pending_chat_members')
          .delete()
          .eq('chat_id', chatId)
          .eq('user_id', bId);
      await alice.from('chat_members').insert(
          {'chat_id': chatId, 'user_id': bId, 'public_key': bKeys.publicKey});

      // Admin removes Bob (the per-recipient key model needs no key rotation —
      // removal alone provides forward secrecy).
      await alice.from('chat_members').delete().eq('chat_id', chatId).eq('user_id', bId);

      // The sender's member-key fetch must no longer include Bob.
      final members = await alice
          .from('chat_members')
          .select('user_id, public_key')
          .eq('chat_id', chatId) as List<dynamic>;
      final memberKeys = <String, String>{
        for (final m in members)
          (m as Map)['user_id'] as String: m['public_key'] as String,
      };
      expect(memberKeys.containsKey(bId), isFalse,
          reason: 'removed member must not be a recipient anymore');
      expect(memberKeys.keys.toSet(), {aId});

      // Alice sends a message to the (now Bob-less) member set.
      final svc =
          MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));
      final encrypted =
          await svc.encryptForAllMembers('after Bob was removed', memberKeys);
      final msgId = const Uuid().v4();
      await alice.from('messages').insert([
        for (final e in encrypted.entries)
          {
            'id': msgId,
            'chat_id': chatId,
            'sender_id': aId,
            'recipient_id': e.key,
            'encrypted_content': e.value,
          }
      ]);

      // Bob can neither see a row for himself nor any USER message in the
      // chat (RLS). System messages addressed to him while he was still a
      // member (his own 'joined' announcement) legitimately remain readable —
      // they were encrypted for him at a time he was allowed to read them.
      final bobRows = await bob
          .from('messages')
          .select('id')
          .eq('chat_id', chatId)
          .neq('message_type', 'system') as List<dynamic>;
      expect(bobRows, isEmpty,
          reason: 'a removed member must not be able to read later messages');
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

  // Regression for the production B→A failure: a member whose per-chat key was
  // never registered (e.g. the `newChat` realtime broadcast was missed on
  // reload/offline/join race) is SILENTLY dropped from the recipient set, so
  // the chat is undecryptable for them in both directions. `refreshChats` now
  // self-heals by registering the member's current hybrid public key. This test
  // reproduces the keyless state and the reconciliation (the repo calls
  // `ChatsController._ensureMyKeyRegistered` performs).
  test('self-heal: a member with no registered key is reconciled and reachable',
      () async {
    if (!libExists) {
      markTestSkipped('native crypto lib not built ($libPath)');
      return;
    }

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
    String? chatId;
    try {
      await alice.from('profiles').insert({'id': aId, 'username': 'alice_$suffix'});
      await bob.from('profiles').insert({'id': bId, 'username': 'bob_$suffix'});

      final aKeys = await ChatKeyPairManager.generateDetachedKeyPair();
      final chat =
          await alice.from('chats').insert({'name': 'heal_$suffix'}).select().single();
      chatId = chat['id'] as String;
      await alice.from('chat_members').insert(
          {'chat_id': chatId, 'user_id': aId, 'public_key': aKeys.publicKey});
      // Bob is a member but his key was never registered (missed newChat event).
      await alice.from('chat_members')
          .insert({'chat_id': chatId, 'user_id': bId, 'public_key': null});

      final aliceKeysRepo = ChatMemberKeysRepository(alice);

      // BUG STATE: the keyless member is excluded from the recipient set, so a
      // message sent now would never produce a row for Bob.
      final before = await aliceKeysRepo.getAllPublicKeys(chatId);
      expect(before.containsKey(bId), isFalse,
          reason: 'a member without a registered key is silently dropped');

      // SELF-HEAL: Bob registers his own current hybrid key (exactly what
      // refreshChats → _ensureMyKeyRegistered does on the next refresh).
      final bKeys = await ChatKeyPairManager.generateDetachedKeyPair();
      await ChatMemberKeysRepository(bob).setPublicKey(
          chatId: chatId, userId: bId, publicKeyPem: bKeys.publicKey);

      final after = await aliceKeysRepo.getAllPublicKeys(chatId);
      expect(after.keys.toSet(), {aId, bId},
          reason: 'after self-heal Bob is a reachable recipient again');

      // And the full encrypt→decrypt path now covers Bob.
      final svc =
          MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));
      const plaintext = 'reachable after self-heal 🔐';
      final encrypted = await svc.encryptForAllMembers(plaintext, after);
      expect(encrypted.containsKey(bId), isTrue);
      final decrypted =
          await svc.decryptMessage(encrypted[bId]!, bKeys.privateKey);
      expect(decrypted, plaintext);
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
