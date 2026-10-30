// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// A call signal carries the SDP — and with it the DTLS fingerprints that key
// the audio. Two things therefore matter beyond "it round-trips": a broken or
// foreign plaintext is refused whole, and a sealed signal is bound to its own
// domain, so it can neither be replayed later nor passed off as a message.
// The seal part needs the native lib (`./native/build.sh`); skips otherwise.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/ed25519.dart';
import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart'
    show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/kem_key_binding.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/calls/call_signal.dart';

final _jetzt = DateTime.utc(2026, 10, 3, 2);

void main() {
  group('Signal-Format', () {
    test('Neustart-Runde übersteht encode und tryDecode samt Nummer', () {
      final sig = CallSignal(
        type: CallSignalType.restart,
        callId: 'c1',
        sentAt: DateTime.utc(2026, 10, 13),
        sdp: 'OFFER',
        seq: 3,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.type, CallSignalType.restart);
      expect(back.seq, 3);
      expect(back.sdp, 'OFFER');
    });

    test('Neustart ohne Rundennummer wird verworfen', () {
      const raw = '{"k":"chattr_call","t":"restarted","id":"c1","ts":1,"sdp":"A"}';
      expect(CallSignal.tryDecode(raw.replaceFirst('chattr_call', callSignalKind)),
          isNull);
    });

    test('ein unbekannter Typ wird verworfen, nicht halb gelesen', () {
      // What an older app does with `restart`: drop it, the call goes on.
      final raw = '{"k":"$callSignalKind","t":"future","id":"c1","ts":1,"sdp":"A"}';
      expect(CallSignal.tryDecode(raw), isNull);
    });

    test('Einladung übersteht den Rundlauf', () {
      final s = CallSignal(
          type: CallSignalType.invite,
          callId: 'c1',
          sentAt: _jetzt,
          sdp: 'v=0 …');
      final back = CallSignal.tryDecode(s.encode())!;
      expect(back.type, CallSignalType.invite);
      expect(back.callId, 'c1');
      expect(back.sdp, 'v=0 …');
      expect(back.sentAt, _jetzt);
    });

    test('Ende trägt seinen Grund', () {
      final s = CallSignal(
          type: CallSignalType.end,
          callId: 'c1',
          sentAt: _jetzt,
          reason: 'busy');
      expect(CallSignal.tryDecode(s.encode())!.reason, 'busy');
    });

    test('Fremdes und Kaputtes wird ganz verworfen', () {
      for (final p in [
        'hallo',
        '[]',
        jsonEncode({'t': 'invite', 'id': 'c', 'ts': 1, 'sdp': 'x'}), // kein k
        jsonEncode({'k': callSignalKind, 't': 'ring', 'id': 'c', 'ts': 1}),
        jsonEncode({'k': callSignalKind, 't': 'end', 'id': '', 'ts': 1}),
        jsonEncode({'k': callSignalKind, 't': 'end', 'id': 'c', 'ts': 'x'}),
        // Einladung ohne Beschreibung ist nutzlos.
        jsonEncode({'k': callSignalKind, 't': 'invite', 'id': 'c', 'ts': 1}),
      ]) {
        expect(CallSignal.tryDecode(p), isNull, reason: p);
      }
    });

    test('alte Signale gelten nicht mehr (Wiedereinspielen)', () {
      final s = CallSignal(
          type: CallSignalType.invite, callId: 'c', sentAt: _jetzt, sdp: 'x');
      expect(s.isFresh(_jetzt.add(const Duration(seconds: 90))), isTrue);
      expect(s.isFresh(_jetzt.add(const Duration(minutes: 3))), isFalse);
      // Auch eine vorgehende Uhr beim Absender hat eine Grenze.
      expect(s.isFresh(_jetzt.subtract(const Duration(minutes: 3))), isFalse);
    });
  });

  group('Versiegelung', () {
    const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
    final libExists = File(libPath).existsSync();
    final skip = libExists ? false : 'native lib not built ($libPath)';

    late ChatKeyPairManager keyManager;
    late MessageEncryptionService service;

    setUpAll(() {
      if (libExists) mlKemLibraryPathOverride = libPath;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    });
    tearDownAll(() => debugDefaultTargetPlatformOverride = null);

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      keyManager = ChatKeyPairManager(const FlutterSecureStorage());
      service = MessageEncryptionService(keyManager);
    });

    test('ein Anruf-Signal lässt sich nicht als Nachricht öffnen', () async {
      const chat = 'chat-call';
      await keyManager.generateKeyPairForChat(chat);
      final pub = KemKeyBinding.attachSignature(
          (await keyManager.getPublicKey(chat))!, 'v4-capable-sig');
      final id = await Ed25519Keys.generate();

      final callCtx = MessageContext(
          chatId: callSignalContextChatId(chat),
          senderId: 'alice',
          messageId: 'sig-1');
      final plaintext = CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: _jetzt,
              sdp: 'fingerprint:sha-256 AA:BB')
          .encode();
      final sig =
          await Ed25519Keys.signBase64(id, callCtx.signingBytes(plaintext));
      final env = await service.encryptForRecipient(plaintext, pub,
          context: callCtx, signatureB64: sig);
      expect((jsonDecode(env) as Map)['v'], 4);

      final keys = await keyManager.getAllPrivateKeys(chat);

      // Im eigenen Bereich: geht auf.
      final opened =
          await service.decryptEnvelopeTryKeys(env, keys, context: callCtx);
      expect(CallSignal.tryDecode(opened.plaintext)!.callId, 'c1');
      expect(opened.signatureB64, sig);

      // Als Nachricht desselben Chats wieder eingespielt: geht NICHT auf.
      const asMessage =
          MessageContext(chatId: chat, senderId: 'alice', messageId: 'sig-1');
      await expectLater(
        service.decryptEnvelopeTryKeys(env, keys, context: asMessage),
        throwsA(anything),
      );

      // Mit falschem Absender: geht NICHT auf.
      final forged = MessageContext(
          chatId: callSignalContextChatId(chat),
          senderId: 'mallory',
          messageId: 'sig-1');
      await expectLater(
        service.decryptEnvelopeTryKeys(env, keys, context: forged),
        throwsA(anything),
      );
    }, skip: skip);
  });
}
