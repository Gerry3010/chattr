// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-62: offline, 1:1 chats were titled "Chat <id>" because the member list
// and the peer's profile only ever came from the server. These tests pin the
// roster cache that keeps both on the device, and the line it must not cross:
// a stored profile is good for a name, never for an identity key.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/encryption_service.dart';
import 'package:chattr/features/chats/chat_members_controller.dart';
import 'package:chattr/features/chats/chat_members_repository.dart';
import 'package:chattr/features/chats/roster_store.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/profiles/profiles_repository.dart';

import 'support/memory_roster_store.dart';

const _chat = 'cb97c93c-0000-4000-8000-000000000001';
const _me = 'aaaaaaaa-0000-4000-8000-000000000001';
const _peer = 'bbbbbbbb-0000-4000-8000-000000000002';
const _newcomer = 'cccccccc-0000-4000-8000-000000000003';

Profile _profile(String id, String name, {String? key}) => Profile(
      id: id,
      username: name,
      createdAt: DateTime.utc(2026, 1, 1),
      identityPublicKey: key,
    );

/// Answers like the server, or throws like airplane mode.
class _FakeMembersRepo implements ChatMembersRepository {
  List<String> members = const [_me, _peer];
  bool offline = false;
  int calls = 0;

  /// When set, the next answer waits for it: lets a test look at the list
  /// that is served BEFORE the server has spoken.
  Completer<void>? gate;

  @override
  Future<List<String>> getChatMembers(String chatId) async {
    calls++;
    final wait = gate;
    if (wait != null) {
      gate = null;
      await wait.future;
    }
    if (offline) throw Exception('SocketException: no network');
    return members;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfilesRepo implements ProfilesRepository {
  final Map<String, Profile?> server = {};
  bool offline = false;

  @override
  Future<Profile?> fetchProfile(String userId) async {
    if (offline) throw Exception('SocketException: no network');
    return server[userId];
  }

  @override
  Future<Map<String, Profile?>> fetchProfiles(List<String> userIds) async {
    if (offline) throw Exception('SocketException: no network');
    return {for (final id in userIds) id: server[id]};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Passes JSON through, as in local_unread_repository_test: what is under test
/// is the table layout and the round trip, not the cipher.
class _PassthroughEncryption extends EncryptionService {
  _PassthroughEncryption()
      : super(
          EncryptionKeyManager(
            const FlutterSecureStorage(),
            BiometricAuthService(),
          ),
        );

  final _blobs = <String, Map<String, dynamic>>{};
  var _seq = 0;

  @override
  Future<String?> encryptJson(Map<String, dynamic> json) async {
    final handle = 'blob-${_seq++}';
    _blobs[handle] = json;
    return handle;
  }

  @override
  Future<Map<String, dynamic>?> decryptJson(String ciphertext) async =>
      _blobs[ciphertext];
}

/// Lets the fire-and-forget writes and the background confirmation land.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('ChatMembersCache', () {
    test('meldet nur echte Änderungen und vergisst bei leerer Antwort', () async {
      final store = MemoryRosterStore();
      final cache = ChatMembersCache(store);

      expect(cache.put(_chat, const [_me, _peer]), isTrue);
      expect(cache.put(_chat, const [_peer, _me]), isFalse,
          reason: 'Reihenfolge ist keine Änderung');
      await _settle();
      expect(store.members[_chat], [_me, _peer]);

      // Empty = no longer a member: drop it, never store an empty list.
      expect(cache.put(_chat, const []), isTrue);
      await _settle();
      expect(cache.membersOf(_chat), isNull);
      expect(store.members.containsKey(_chat), isFalse);
    });

    test('Laden von der Platte überschreibt keine Serverantwort', () {
      final cache = ChatMembersCache(MemoryRosterStore());
      cache.put(_chat, const [_me, _newcomer]);
      cache.hydrate({_chat: const [_me, _peer]});
      expect(cache.membersOf(_chat), [_me, _newcomer]);
    });
  });

  group('chatMembersProvider', () {
    late _FakeMembersRepo repo;
    late MemoryRosterStore store;
    late ProviderContainer container;

    setUp(() {
      repo = _FakeMembersRepo();
      store = MemoryRosterStore();
      container = ProviderContainer(
        overrides: [
          chatMembersRepositoryProvider.overrideWithValue(repo),
          rosterStoreProvider.overrideWithValue(store),
        ],
        // Riverpod would retry a failed fetch for ~40 s; the tests want the
        // first answer.
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
    });

    test('ohne Netz liefert er den gespeicherten Stand', () async {
      container.read(chatMembersCacheProvider).hydrate({_chat: [_me, _peer]});
      repo.offline = true;

      final sub = container.listen(chatMembersProvider(_chat), (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(chatMembersProvider(_chat).future),
          [_me, _peer]);
      await _settle();
      expect(sub.read().value, [_me, _peer],
          reason: 'der fehlgeschlagene Abgleich darf die Liste nicht leeren');
    });

    test('ohne gespeicherten Stand und ohne Netz bleibt es ein Fehler', () async {
      repo.offline = true;
      final sub = container.listen(chatMembersProvider(_chat), (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        container.read(chatMembersProvider(_chat).future),
        throwsException,
      );
    });

    test('eine geänderte Serverantwort ersetzt den gespeicherten Stand',
        () async {
      container.read(chatMembersCacheProvider).hydrate({_chat: [_me, _peer]});
      repo.members = const [_me, _peer, _newcomer];
      final server = Completer<void>();
      repo.gate = server;

      final sub = container.listen(chatMembersProvider(_chat), (_, _) {});
      addTearDown(sub.close);

      // Served from the device while the server has not answered yet.
      expect(await container.read(chatMembersProvider(_chat).future),
          [_me, _peer]);

      server.complete();
      await _settle();
      expect(await container.read(chatMembersProvider(_chat).future),
          [_me, _peer, _newcomer]);
      await _settle();
      expect(store.members[_chat], [_me, _peer, _newcomer]);
      // Served, confirmed, re-run once, confirmed again: no endless refetch.
      expect(repo.calls, 2);
    });

    test('erste Serverantwort wird für den nächsten Start gespeichert',
        () async {
      final sub = container.listen(chatMembersProvider(_chat), (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(chatMembersProvider(_chat).future),
          [_me, _peer]);
      await _settle();
      expect(store.members[_chat], [_me, _peer]);
    });
  });

  group('ProfilesController mit gespeichertem Stand', () {
    late _FakeProfilesRepo repo;
    late MemoryRosterStore store;
    late ProviderContainer container;
    late ProfilesController profiles;

    setUp(() {
      repo = _FakeProfilesRepo();
      store = MemoryRosterStore();
      container = ProviderContainer(overrides: [
        eventBusProvider.overrideWithValue(null),
        rosterStoreProvider.overrideWithValue(store),
        profilesControllerProvider
            .overrideWith((ref) => ProfilesController(ref, repo)),
      ]);
      addTearDown(container.dispose);
      profiles = container.read(profilesControllerProvider.notifier);
    });

    test('Name und Farbe sind sofort da, ganz ohne Netz', () {
      repo.offline = true;
      profiles.hydrate({_peer: _profile(_peer, 'Finnleyyyy', key: 'old-key')});
      final state = container.read(profilesControllerProvider);
      expect(state[_peer]?.username, 'Finnleyyyy');
      expect(profiles.isProfileCached(_peer), isTrue);
    });

    test('ein gespeichertes Profil geht nie als frisch an die Schlüsselprüfung',
        () async {
      profiles.hydrate({_peer: _profile(_peer, 'Finnleyyyy', key: 'old-key')});

      // Offline the identity paths get an error, as before CHAT-62, not the
      // stored key. They each have their own offline handling.
      repo.offline = true;
      await expectLater(profiles.getProfile(_peer), throwsException);

      // Online they get the server's current key.
      repo.offline = false;
      repo.server[_peer] = _profile(_peer, 'Finnleyyyy', key: 'new-key');
      final fresh = await profiles.getProfile(_peer);
      expect(fresh.identityPublicKey, 'new-key');
    });

    test('refreshStale bestätigt, speichert und räumt Verschwundene ab',
        () async {
      store.profiles[_newcomer] = _profile(_newcomer, 'Weg');
      profiles.hydrate({
        _peer: _profile(_peer, 'Alter Name'),
        _newcomer: _profile(_newcomer, 'Weg'),
      });
      repo.server[_peer] = _profile(_peer, 'Neuer Name');
      // _newcomer: the server answers null — deleted or no longer visible.

      await profiles.refreshStale();
      await _settle();

      final state = container.read(profilesControllerProvider);
      expect(state[_peer]?.username, 'Neuer Name');
      expect(state.containsKey(_newcomer), isFalse);
      expect(store.profiles[_peer]?.username, 'Neuer Name');
      expect(store.profiles.containsKey(_newcomer), isFalse);
    });

    test('refreshStale ohne Netz wirft nicht und lässt die Namen stehen',
        () async {
      profiles.hydrate({_peer: _profile(_peer, 'Finnleyyyy')});
      repo.offline = true;
      await profiles.refreshStale();
      expect(container.read(profilesControllerProvider)[_peer]?.username,
          'Finnleyyyy');
    });

    test('Laden von der Platte überschreibt kein frisches Profil', () async {
      repo.server[_peer] = _profile(_peer, 'Frisch');
      await profiles.loadProfile(_peer);
      profiles.hydrate({_peer: _profile(_peer, 'Alt')});
      expect(container.read(profilesControllerProvider)[_peer]?.username,
          'Frisch');
      // Still fresh: no second fetch needed.
      repo.offline = true;
      expect((await profiles.getProfile(_peer)).username, 'Frisch');
    });
  });

  group('SqliteRosterStore', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // Its own directory: `flutter test` runs files in parallel, and the
      // DatabaseService singleton would otherwise share one chattr.db with
      // every other DB test ("database is locked").
      await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('chattr_db_').path,
      );
      FlutterSecureStorage.setMockInitialValues({});
    });

    setUp(() async {
      await DatabaseService.instance.close();
      await DatabaseService.instance.deleteDatabase();
    });

    test('Mitglieder und Profile überstehen einen Neustart', () async {
      final crypto = _PassthroughEncryption();
      final store = SqliteRosterStore(DatabaseService.instance, crypto);
      await store.saveMembers(_chat, const [_me, _peer]);
      await store.saveProfiles([
        _profile(_peer, 'Finnleyyyy', key: 'k'),
        Profile.nonExistent(_newcomer),
      ]);

      await DatabaseService.instance.close();
      final reopened = SqliteRosterStore(DatabaseService.instance, crypto);
      expect(await reopened.loadMembers(), {_chat: [_me, _peer]});
      final loaded = await reopened.loadProfiles();
      expect(loaded.keys, [_peer],
          reason: 'ein Platzhalter für Unbekannte wird nicht gespeichert');
      expect(loaded[_peer]?.identityPublicKey, 'k');

      await reopened.deleteProfiles([_peer]);
      await reopened.deleteMembers(_chat);
      expect(await reopened.loadProfiles(), isEmpty);
      expect(await reopened.loadMembers(), isEmpty);
    });

    test('clearAll leert beide Tabellen', () async {
      final store =
          SqliteRosterStore(DatabaseService.instance, _PassthroughEncryption());
      await store.saveMembers(_chat, const [_me, _peer]);
      await store.saveProfiles([_profile(_peer, 'X')]);
      await store.clearAll();
      expect(await store.loadMembers(), isEmpty);
      expect(await store.loadProfiles(), isEmpty);
    });
  });
}
