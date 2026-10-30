// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-23, Gerry's iPhone: the app opened on "Noch keine Chats" with all
// his chats on the phone. Two ways led there, and neither recovered:
//  - Face ID cancelled at start: the controller returned, the list stayed
//    empty, nothing ever asked again.
//  - Offline at start: the local chats were read, then the server refresh
//    threw, and the catch emptied the list again and skipped every listener.

import 'dart:async';
import 'dart:io';

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

/// Answers the chat gate from a queue; unlocking through the lock screen
/// marks the session like the real service does.
class _Biometrics extends BiometricAuthService {
  _Biometrics(this.answers);

  final List<bool> answers;
  int asked = 0;
  bool _session = false;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String localizedReason = '',
    bool forcePrompt = false,
  }) async {
    if (_session && !forcePrompt) return true;
    asked++;
    final ok = answers.isEmpty ? true : answers.removeAt(0);
    if (ok) _session = true;
    return ok;
  }
}

class _OfflineRepo implements ChatsRepository {
  @override
  Future<List<Chat>> fetchChats([Iterable<String>? chatIds]) async =>
      throw const SocketException('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Local implements ChatsLocalRepository {
  _Local(this.chats);

  final Map<String, Chat> chats;

  @override
  Future<Map<String, Chat>> loadChats() async => Map.of(chats);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Biometrics biometrics;
  late ProviderContainer container;
  late Provider<ChatsController> holder;

  void start({required List<bool> gate}) {
    FlutterSecureStorage.setMockInitialValues({});
    BiometricAuthService.resetSession();
    ChatsController.resetBiometricGate();
    biometrics = _Biometrics(gate);
    final bus = _Bus();
    holder = Provider<ChatsController>((ref) {
      final c = ChatsController(
        ref,
        _OfflineRepo(),
        _NoKeys(),
        _Local({'a': _chat('a'), 'b': _chat('b')}),
        biometrics,
        _NoKeyPairs(),
        bus,
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
  }

  test('Face ID abgebrochen: gesperrt statt „Noch keine Chats“, danach geladen',
      () async {
    start(gate: [false]);
    final chats = container.read(holder);
    await _settle();

    expect(chats.state, isEmpty);
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.locked);
    expect(container.read(appLockControllerProvider).locked, isTrue,
        reason: 'der Sperrbildschirm muss oben liegen, auch ohne App-Sperre');

    // „Biometrie verwenden“ auf dem Sperrbildschirm.
    final ok = await container
        .read(appLockControllerProvider.notifier)
        .unlockWithBiometrics(localizedReason: 'test');
    expect(ok, isTrue);
    await _settle();

    expect(chats.state.map((c) => c.id), unorderedEquals(['a', 'b']));
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.ready);
    expect(biometrics.asked, 2,
        reason: 'nach dem Entsperren fragt die Liste nicht ein drittes Mal');
  });

  test('ohne Netz gestartet: die lokale Liste bleibt stehen', () async {
    start(gate: [true]);
    final chats = container.read(holder);
    await _settle();

    expect(chats.state.map((c) => c.id), unorderedEquals(['a', 'b']),
        reason: 'früher leerte der catch die Liste wieder');
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.ready);
    expect(container.read(appLockControllerProvider).locked, isFalse);
  });

  test('das Schließen der Abfrage selbst fragt nicht noch einmal', () async {
    // 2026-10-24 am Galaxy: Die Fingerabdruck-Abfrage macht die App nur
    // inaktiv; schließt man sie, kommt ein „resumed“. Darauf erneut zu fragen
    // holte die Abfrage nach jedem Abbruch sofort zurück, ohne Ende.
    start(gate: [false, false, false]);
    container.read(holder);
    await _settle();
    expect(biometrics.asked, 1);

    container
        .read(appLifecycleServiceProvider)
        .notifyResumed(fromBackground: false);
    await _settle();
    expect(biometrics.asked, 1);
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.locked);
  });

  test('Rückkehr in die App nach Abbruch fragt erneut und lädt', () async {
    start(gate: [false, true]);
    final chats = container.read(holder);
    await _settle();
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.locked);

    container.read(appLifecycleServiceProvider).notifyResumed();
    await _settle();

    expect(chats.state.map((c) => c.id), unorderedEquals(['a', 'b']));
    expect(container.read(chatsLoadStatusProvider), ChatsLoadStatus.ready);
    expect(container.read(appLockControllerProvider).locked, isFalse,
        reason: 'die Liste hat selbst entsperrt, der Sperrbildschirm geht weg');
  });
}
