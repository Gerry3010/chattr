// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/network/device_connectivity.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/encryption_service.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/chats/chat_member_keys_repository.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_controller.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';
import 'package:chattr/features/messages/messages_repository.dart';
import 'package:chattr/features/messages/outgoing_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

/// Passes JSON through: under test is what the controller stores, not the
/// cipher (same as roster_cache_test).
class _PassthroughEncryption extends EncryptionService {
  _PassthroughEncryption()
      : super(EncryptionKeyManager(
          const FlutterSecureStorage(),
          BiometricAuthService(),
        ));

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

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  late ProviderContainer container;
  late MessagesLocalRepository local;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Own directory: test files run in parallel and share the singleton.
    await databaseFactory.setDatabasesPath(
      Directory.systemTemp.createTempSync('chattr_unsent_').path,
    );
    FlutterSecureStorage.setMockInitialValues({});
  });

  setUp(() async {
    await DatabaseService.instance.close();
    await DatabaseService.instance.deleteDatabase();
    // The phone knows it has no network; one test below lifts that.
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        deviceOfflineProvider.overrideWithBuild((ref, _) => true),
      ],
    );
    local = MessagesLocalRepository(
      DatabaseService.instance,
      _PassthroughEncryption(),
      () => 'me',
    );
  });

  tearDown(() => container.dispose());

  /// A controller whose server is unreachable (nothing listens on port 9),
  /// with no event bus, so it does not run its own start-up.
  MessagesController offlineController([ProviderContainer? on]) {
    final offline = SupabaseClient('http://127.0.0.1:9', 'anon');
    final keys = ChatKeyPairManager(const FlutterSecureStorage());
    return MessagesController(
      (on ?? container).read(_refProvider),
      MessagesRepository(offline),
      ChatMemberKeysRepository(offline),
      local,
      BiometricAuthService(),
      keys,
      MessageEncryptionService(keys),
      null,
      'me',
      'c1',
    );
  }

  Future<Message> stored(String id) async =>
      (await local.getMessage('c1', id))! as Message;

  group('Senden ohne Netz (CHAT-66)', () {
    test('die Blase bleibt, rot, mit Grund „kein Netz“, und zwar sofort',
        () async {
      final c = offlineController();
      final watch = Stopwatch()..start();
      final m = await c.sendMessage('Hallo offline');
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'ohne Netz wartet niemand auf postgrests Wiederholungen');

      expect(m.sendState, LocalSendState.failed);
      expect(m.sendFailure, SendFailure.network);
      expect(c.state.single.id, m.id, reason: 'die Blase steht im Verlauf');
      expect((c.state.single as Message).sendState, LocalSendState.failed);

      final row = await stored(m.id);
      expect(row.decryptedContent, 'Hallo offline',
          reason: 'der Text liegt auf dem Gerät, nichts geht verloren');
      expect(row.sendState, LocalSendState.failed);
    });

    test('Erneut senden: gleiche ID, Zeit des neuen Versuchs, ans Ende',
        () async {
      final c = offlineController();
      final first = await c.sendMessage('erste');
      final second = await c.sendMessage('zweite');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final retried = await c.retrySend(first.id);

      expect(retried!.id, first.id);
      expect(retried.createdAt.isAfter(first.createdAt), isTrue);
      expect(retried.sendState, LocalSendState.failed,
          reason: 'immer noch offline');
      expect(c.state.map((m) => m.id), [second.id, first.id]);
      expect((await stored(first.id)).createdAt, retried.createdAt,
          reason: 'die Sortierspalte zieht mit');
    });

    test('Verwerfen löscht nur lokal, und nur Ungesendetes', () async {
      final c = offlineController();
      final m = await c.sendMessage('weg damit');

      expect(await c.discardUnsent(m.id), isTrue);
      expect(c.state, isEmpty);
      expect(await local.getMessage('c1', m.id), isNull);
      expect(await c.discardUnsent('gibt-es-nicht'), isFalse);
    });

    test('Weiterleiten/Teilen bekommen den Fehler, die Blase bleibt trotzdem',
        () async {
      final c = offlineController();
      await expectLater(
        c.sendMessage('geteilt', rethrowFailure: true),
        throwsA(isA<DeviceOfflineException>()),
      );
      final row = (await local.loadMessages('c1', limit: 10)).single as Message;
      expect(row.sendState, LocalSendState.failed);
    });

    test('Netz da, Server antwortet nicht: rot nach den Wiederholungen',
        () async {
      final online = ProviderContainer(retry: (_, _) => null);
      addTearDown(online.dispose);
      final c = offlineController(online);
      final m = await c.sendMessage('Server weg');
      expect(m.sendState, LocalSendState.failed);
      expect(m.sendFailure, SendFailure.network);
      await expectLater(
        c.sendMessage('geteilt', rethrowFailure: true),
        throwsA(isA<ClientException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('nach einem Neustart: eine hängengebliebene Sendung zeigt sich rot',
        () async {
      // As if the app died mid-send: the row on disk still says pending.
      await local.saveMessage(Message(
        id: 'cut-off',
        chatId: 'c1',
        senderId: 'me',
        recipientId: 'me',
        createdAt: DateTime.utc(2026, 10, 30),
        decryptedContent: 'abgebrochen',
        sendState: LocalSendState.pending,
      ));

      final c = offlineController();
      await c.resync();

      final shown = c.state.single as Message;
      expect(shown.sendState, LocalSendState.failed);
      expect(shown.isUnsent, isTrue);
    });
  });
}
