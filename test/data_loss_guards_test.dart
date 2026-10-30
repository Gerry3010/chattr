// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Regression tests for the two confirmed data-loss paths:
//
//  B1: an OFFLINE app launch must never wipe local data. gotrue throws
//      AuthRetryableFetchException for network failures and that class
//      *extends* AuthException — a plain `on AuthException` catch treats
//      "offline" as "server rejected the token" and wipes key + DB + all
//      chat keys (the server has already cleared read ciphertext, so this
//      destroys the only copy of the chat history).
//
//  B2: an incoming message must only be marked received on the server
//      (which CLEARS the server-side ciphertext) after the decrypted copy
//      was successfully persisted locally. If the local save fails the
//      server copy has to stay intact so the message can be re-fetched.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/events/event_types.dart';
import 'package:chattr/core/init/app_init.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/encryption_service.dart';
import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/messages/global_message_handler.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';
import 'package:chattr/features/messages/messages_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// B2 fakes — every override keeps the underlying (never-initialized) services
// untouched.
// ---------------------------------------------------------------------------

class _FakeLocalRepo extends MessagesLocalRepository {
  _FakeLocalRepo({required this.saveThrows})
      : super(
          DatabaseService.instance,
          EncryptionService(
            EncryptionKeyManager(
              const FlutterSecureStorage(),
              BiometricAuthService(),
            ),
          ),
        );

  final bool saveThrows;
  final saved = <MessageInterface>[];
  bool markedReceivedLocally = false;

  @override
  Future<bool> hasMessage(String messageId) async => false;

  @override
  Future<void> saveMessage(MessageInterface message,
      {bool update = false}) async {
    if (saveThrows) {
      throw Exception('simulated persist failure (e.g. AES key unavailable)');
    }
    saved.add(message);
  }

  @override
  Future<void> markAsReceived(
    String chatId,
    String messageId,
    String userId, {
    DateTime? timestamp,
  }) async {
    markedReceivedLocally = true;
  }
}

class _RecordingRemoteRepo extends MessagesRepository {
  _RecordingRemoteRepo() : super(SupabaseClient('http://127.0.0.1:1', 'k'));

  bool markAsReceivedCalled = false;

  @override
  Future<DateTime?> markAsReceived(
    String chatId,
    String messageId,
    String userId,
  ) async {
    markAsReceivedCalled = true;
    return DateTime.now();
  }
}

class _FakeKeyManager extends ChatKeyPairManager {
  _FakeKeyManager() : super(const FlutterSecureStorage());

  @override
  Future<String?> getPrivateKey(String chatId) async => 'fake-private-key';

  @override
  Future<List<String>> getAllPrivateKeys(String chatId) async =>
      ['fake-private-key'];
}

class _FakeEncryption extends MessageEncryptionService {
  _FakeEncryption() : super(_FakeKeyManager());

  @override
  Future<String> decryptMessage(
    String ciphertext,
    String privateKeyCombined, {
    MessageContext? context,
  }) async =>
      'decrypted plaintext';

  @override
  Future<String> decryptMessageTryKeys(
    String ciphertext,
    List<String> privateKeys, {
    MessageContext? context,
    Future<String?> Function(String prekeyId)? prekeyResolver,
  }) async =>
      'decrypted plaintext';

  @override
  Future<DecryptedEnvelope> decryptEnvelopeTryKeys(
    String ciphertext,
    List<String> privateKeys, {
    MessageContext? context,
    Future<String?> Function(String prekeyId)? prekeyResolver,
  }) async =>
      const DecryptedEnvelope(plaintext: 'decrypted plaintext', version: 3);
}

/// Captures a real [Ref]. The guarded paths under test return before any
/// ref.read happens, but the constructor requires one.
Ref _obtainRef(ProviderContainer container) {
  late Ref captured;
  final p = Provider<void>((ref) => captured = ref);
  container.read(p);
  return captured;
}

GlobalMessageHandler _handler({
  required _FakeLocalRepo localRepo,
  required _RecordingRemoteRepo remoteRepo,
  required ProviderContainer container,
}) {
  return GlobalMessageHandler(
    _obtainRef(container),
    remoteRepo,
    localRepo,
    _FakeKeyManager(),
    _FakeEncryption(),
    null, // no event bus — handleNewMessage is invoked directly
    'user-1',
  );
}

NewMessageEvent _incomingEvent() => NewMessageEvent(
      chatId: 'chat-1',
      messageId: 'msg-1',
      senderId: 'sender-1',
      content: '{"v":3,"payload":"irrelevant-fake"}',
      messageType: MessageType.user,
    );

void main() {
  group('B1: offline launch must not wipe', () {
    test('AuthRetryableFetchException (offline) never wipes, even with key',
        () {
      final offline = AuthRetryableFetchException(
        message: 'SocketException: network unreachable',
        statusCode: null,
      );
      expect(
        AppInit.isAccountGoneVerdict(offline, keyExists: true),
        isFalse,
        reason: 'a single offline launch must never destroy local data',
      );
      expect(
        AppInit.isAccountGoneVerdict(offline, keyExists: false),
        isFalse,
      );
    });

    test('account-gone (user_not_found) wipes only when a prior key exists', () {
      final gone = AuthApiException('User from sub claim in JWT does not exist',
          code: 'user_not_found');
      expect(
        AppInit.isAccountGoneVerdict(gone, keyExists: true),
        isTrue,
      );
      expect(
        AppInit.isAccountGoneVerdict(gone, keyExists: false),
        isFalse,
      );
    });

    test('reused/rotated refresh token (PWA<->tab race) never wipes', () {
      // An installed PWA and the still-open browser tab share one persisted
      // session; whichever rotates the refresh token first makes the other's
      // refresh fail with refresh_token_not_found / bad_jwt. That is a benign
      // concurrency artifact — it must NEVER destroy the only local copy of
      // already-read messages.
      for (final code in ['refresh_token_not_found', 'bad_jwt',
          'session_not_found', 'session_expired']) {
        final raced = AuthApiException('token problem', code: code);
        expect(
          AppInit.isAccountGoneVerdict(raced, keyExists: true),
          isFalse,
          reason: 'a $code refresh failure must not wipe local data',
        );
      }
      // A plain AuthException with no explicit code is likewise ambiguous.
      expect(
        AppInit.isAccountGoneVerdict(
          AuthApiException('invalid refresh token'),
          keyExists: true,
        ),
        isFalse,
      );
    });

    test('unknown/transient errors never wipe', () {
      expect(
        AppInit.isAccountGoneVerdict(
          Exception('something else'),
          keyExists: true,
        ),
        isFalse,
      );
    });
  });

  group('B2: server ciphertext only cleared after successful local persist',
      () {
    test('failed local save → markAsReceived is NOT called', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final localRepo = _FakeLocalRepo(saveThrows: true);
      final remoteRepo = _RecordingRemoteRepo();
      final handler = _handler(
        localRepo: localRepo,
        remoteRepo: remoteRepo,
        container: container,
      );

      await handler.handleNewMessage(_incomingEvent());

      expect(localRepo.saved, isEmpty);
      expect(
        remoteRepo.markAsReceivedCalled,
        isFalse,
        reason: 'clearing the server copy after a failed persist loses the '
            'message on both sides',
      );
    });

    test('successful local save → markAsReceived IS called', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final localRepo = _FakeLocalRepo(saveThrows: false);
      final remoteRepo = _RecordingRemoteRepo();
      final handler = _handler(
        localRepo: localRepo,
        remoteRepo: remoteRepo,
        container: container,
      );

      await handler.handleNewMessage(_incomingEvent());

      expect(localRepo.saved, hasLength(1));
      expect(localRepo.saved.single.decryptedContent, 'decrypted plaintext');
      expect(remoteRepo.markAsReceivedCalled, isTrue);
      expect(localRepo.markedReceivedLocally, isTrue);
    });
  });
}
