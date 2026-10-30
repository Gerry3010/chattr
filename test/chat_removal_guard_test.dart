// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-32: a chat missing from a successful fetch was deleted locally at once,
// with every message in it. A server that answered "no chats" (a broken RPC, an
// RLS regression) would have wiped the history of the whole fleet on the next
// resume. Mass removals are now held until the server has said the same thing
// over days and several fetches.

import 'dart:async';

import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/core/events/event_types.dart';
import 'package:chattr/core/lifecycle/app_lifecycle_service.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/identity_key_manager.dart';
import 'package:chattr/core/security/passcode_manager.dart';
import 'package:chattr/core/security/security_providers.dart';
import 'package:chattr/features/app_lock/app_lock_controller.dart';
import 'package:chattr/features/chats/chat_member_keys_repository.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chat_removal_guard.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/chats_load_status.dart';
import 'package:chattr/features/chats/chats_local_repository.dart';
import 'package:chattr/features/chats/chats_repository.dart';
import 'package:chattr/features/mcp/mcp_auto_join_controller.dart';
import 'package:chattr/features/messages/global_message_handler.dart';
import 'package:chattr/features/messages/messages_local_provider.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime.utc(2026, 10, 28, 12);

  group('looksLikeMassRemoval', () {
    test('ein einzelner Chat fehlt: normal', () {
      expect(
        looksLikeMassRemoval(
            removed: 1, established: 5, fullFetch: true, fetched: 4),
        isFalse,
      );
    });

    test('voller Abruf ganz leer: verdächtig, auch bei nur einem Chat', () {
      expect(
        looksLikeMassRemoval(
            removed: 1, established: 1, fullFetch: true, fetched: 0),
        isTrue,
      );
    });

    test('die Hälfte auf einmal: verdächtig', () {
      expect(
        looksLikeMassRemoval(
            removed: 2, established: 4, fullFetch: true, fetched: 2),
        isTrue,
      );
      expect(
        looksLikeMassRemoval(
            removed: 2, established: 5, fullFetch: true, fetched: 3),
        isFalse,
      );
    });

    test('gezielter Abruf ohne Treffer ist kein Massenfall', () {
      expect(
        looksLikeMassRemoval(
            removed: 1, established: 1, fullFetch: false, fetched: 0),
        isFalse,
      );
    });
  });

  group('planChatRemovals', () {
    test('unverdächtig: sofort weg, ein alter Vermerk fällt mit', () {
      final plan = planChatRemovals(
        candidates: ['a'],
        presentIds: {'b'},
        localIds: {'a', 'b'},
        records: {'a': MissingChatRecord(firstSeen: now, fetches: 1)},
        suspicious: false,
        now: now,
      );
      expect(plan.remove, ['a']);
      expect(plan.hold, isEmpty);
      expect(plan.records, isEmpty);
    });

    test('verdächtig: gehalten und vermerkt', () {
      final plan = planChatRemovals(
        candidates: ['a', 'b'],
        presentIds: {},
        localIds: {'a', 'b'},
        records: {},
        suspicious: true,
        now: now,
      );
      expect(plan.remove, isEmpty);
      expect(plan.hold, ['a', 'b']);
      expect(plan.records['a'], MissingChatRecord(firstSeen: now, fetches: 1));
    });

    test('erst nach Karenz UND genug Abrufen gelöscht', () {
      var records = <String, MissingChatRecord>{};
      ChatRemovalPlan step(DateTime at) {
        final plan = planChatRemovals(
          candidates: ['a'],
          presentIds: {},
          localIds: {'a'},
          records: records,
          suspicious: true,
          now: at,
        );
        records = plan.records;
        return plan;
      }

      expect(step(now).remove, isEmpty);
      expect(step(now.add(const Duration(hours: 80))).remove, isEmpty,
          reason: 'genug Zeit, aber erst zwei Abrufe');
      expect(step(now.add(const Duration(hours: 81))).remove, ['a']);
      expect(records, isEmpty);
    });

    test('viele Abrufe in kurzer Zeit reichen nicht', () {
      var records = <String, MissingChatRecord>{};
      for (var i = 0; i < 10; i++) {
        final plan = planChatRemovals(
          candidates: ['a'],
          presentIds: {},
          localIds: {'a'},
          records: records,
          suspicious: true,
          now: now.add(Duration(minutes: i)),
        );
        expect(plan.remove, isEmpty);
        records = plan.records;
      }
      expect(records['a']!.fetches, 10);
    });

    test('ein Abruf, der den Chat wieder liefert, vergisst den Vermerk', () {
      final plan = planChatRemovals(
        candidates: [],
        presentIds: {'a'},
        localIds: {'a', 'gone'},
        records: {
          'a': MissingChatRecord(firstSeen: now, fetches: 2),
          'gone': MissingChatRecord(firstSeen: now, fetches: 1),
          'not-local': MissingChatRecord(firstSeen: now, fetches: 1),
        },
        suspicious: false,
        now: now,
      );
      expect(plan.records.keys, ['gone'],
          reason: 'a ist zurück, not-local liegt gar nicht mehr am Gerät');
    });
  });

  group('refreshChats', () {
    late _Local local;
    late _Repo repo;
    late ProviderContainer container;
    late Provider<ChatsController> holder;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      BiometricAuthService.resetSession();
      ChatsController.resetBiometricGate();
      local = _Local({'a': _chat('a'), 'b': _chat('b')});
      repo = _Repo();
      final biometrics = _Biometrics();
      holder = Provider<ChatsController>((ref) {
        final c = ChatsController(
          ref,
          repo,
          _NoKeys(),
          local,
          biometrics,
          _NoKeyPairs(),
          _Bus(),
          'me',
        );
        ref.onDispose(c.dispose);
        return c;
      });
      container = ProviderContainer(overrides: [
        chatsLoadStatusProvider.overrideWith((ref) => ChatsLoadStatus.loading),
        appInForegroundProvider.overrideWithValue(() => true),
        messagesLocalRepositoryProvider.overrideWithValue(_Messages()),
        globalMessageHandlerProvider.overrideWithValue(_Handler()),
        mcpAutoJoinControllerProvider.overrideWithValue(_AutoJoin()),
        identityKeyManagerProvider.overrideWithValue(_Identity()),
        appLockControllerProvider.overrideWith((ref) {
          const storage = FlutterSecureStorage();
          return AppLockController(
            storage,
            PasscodeManager(storage),
            biometrics,
            EncryptionKeyManager(storage, biometrics),
          );
        }),
      ]);
      addTearDown(container.dispose);
    });

    test('Server liefert erfolgreich keine Chats: nichts wird gelöscht',
        () async {
      final chats = container.read(holder);
      await _settle();
      final afterStart = (await ChatRemovalStore().load())['a']!.fetches;
      await chats.refreshChats();
      await _settle();

      expect(local.deleted, isEmpty);
      expect(chats.state.map((c) => c.id), unorderedEquals(['a', 'b']));
      final held = await ChatRemovalStore().load();
      expect(held.keys, unorderedEquals(['a', 'b']));
      expect(held['a']!.fetches, afterStart + 1,
          reason: 'jeder Abruf zählt, gelöscht wird erst nach der Karenz');
    });
  });
}

Chat _chat(String id) => Chat(
      id: id,
      createdAt: DateTime.utc(2026, 7, 1),
      insertedAt: DateTime.utc(2026, 7, 1),
      lastMessageAt: DateTime.utc(2026, 10, 23),
    );

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Answers successfully, with nothing: the broken-RPC case.
class _Repo implements ChatsRepository {
  @override
  Future<List<Chat>> fetchChats([Iterable<String>? chatIds]) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Local implements ChatsLocalRepository {
  _Local(this.chats);

  final Map<String, Chat> chats;
  final deleted = <String>[];

  @override
  Future<Map<String, Chat>> loadChats() async => Map.of(chats);

  @override
  Future<void> markChatAsDeleted(String chatId) async => deleted.add(chatId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Biometrics extends BiometricAuthService {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String localizedReason = '',
    bool forcePrompt = false,
  }) async =>
      true;
}

class _Messages implements MessagesLocalRepository {
  @override
  Future<DateTime?> getUnreadEpoch() async => null;

  @override
  Future<Map<String, int>> countUnread(
    Map<String, DateTime?> lastReadAtByChat, {
    DateTime? fallback,
  }) async =>
      {for (final id in lastReadAtByChat.keys) id: 0};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bus implements EventBusService {
  final _events = StreamController<BusEvent>.broadcast();
  final _resubscribed = StreamController<void>.broadcast();

  @override
  Stream<BusEvent> get eventStream => _events.stream;

  @override
  Stream<void> get onResubscribed => _resubscribed.stream;

  @override
  Future<void> reconnect() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handler implements GlobalMessageHandler {
  @override
  Future<void> catchUpUndelivered() async {}

  @override
  Future<void> reconcileSentReceipts() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AutoJoin implements McpAutoJoinController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Identity implements IdentityKeyManager {
  @override
  Future<String> ensureKeyPair() async => 'pub';

  @override
  Future<String?> publicKeyBase64() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoKeys implements ChatMemberKeysRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoKeyPairs implements ChatKeyPairManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
