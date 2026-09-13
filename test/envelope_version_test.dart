// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// "What happens when a device receives a message it cannot read?" (Gerry,
// 2026-08-14)
//
// Until now: nothing. Decryption threw, the message was never stored and simply
// did not exist for the recipient — no placeholder, no notice. A gap nobody
// sees is a gap nobody reports.
//
// This CANNOT be retrofitted: a client that is out there today stays silent on
// an unknown version forever. The notice therefore has to be there BEFORE the
// envelope version is ever raised — otherwise the very device that would need
// to hear "please update" is the one that cannot.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/envelope_version.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/messages/message_envelopes.dart';

void main() {
  group('Obergrenze', () {
    test('it is derived from the list, not written beside it', () {
      // Two hand-maintained constants drift apart sooner or later — and
      // silently in the dangerous direction: an upper bound running ahead of
      // the actual support would consider a version "known" that nobody can
      // decrypt. The message would then disappear wordlessly again, which is
      // exactly the fault this file is meant to prevent.
      expect(EnvelopeVersions.maxSupported,
          EnvelopeVersions.supported.reduce((a, b) => a > b ? a : b));
    });

    test('anything we can read does not count as too new', () {
      for (final v in EnvelopeVersions.supported) {
        expect(EnvelopeVersions.isTooNew(v), isFalse, reason: 'v$v');
      }
    });

    test('only above that is something too new', () {
      expect(EnvelopeVersions.isTooNew(EnvelopeVersions.maxSupported + 1), isTrue);
      expect(EnvelopeVersions.isTooNew(99), isTrue);
    });

    test('an unknown LOWER version is not "too new"', () {
      // Important for the wording: "please update" would be a lie here and
      // would send somebody chasing a solution that does not exist.
      expect(EnvelopeVersions.isTooNew(2), isFalse);
      expect(EnvelopeVersions.isTooNew(0), isFalse);
      expect(EnvelopeVersions.isTooNew(null), isFalse);
    });
  });

  group('read the version out of the envelope', () {
    test('whole number and string', () {
      expect(EnvelopeVersions.versionOf('{"v":6,"msg":"x"}'), 6);
      expect(EnvelopeVersions.versionOf('{"v":"6"}'), 6);
    });

    test('never throws — it runs on data that is already broken', () {
      for (final s in ['', 'kein json', '[]', '{}', '{"v":null}', '{"v":{}}']) {
        expect(EnvelopeVersions.versionOf(s), isNull, reason: s);
      }
    });
  });

  group('Platzhalter', () {
    test('carries the version it is waiting for', () {
      final n = UnsupportedEnvelopeNotice.tryParse(
          const UnsupportedEnvelopeNotice(6).encode());
      expect(n, isNotNull);
      expect(n!.version, 6);
    });

    test('is not detected in ordinary text', () {
      for (final s in [
        null,
        '',
        'Hallo!',
        '{"_chattr_invite":1}',
        '{"_chattr_location":1}',
        'ich schreibe über _chattr_unsupported',
      ]) {
        expect(UnsupportedEnvelopeNotice.tryParse(s), isNull, reason: '$s');
      }
    });

    test('is valid JSON and marked as an envelope', () {
      final body = const UnsupportedEnvelopeNotice(7).encode();
      expect(jsonDecode(body), isA<Map<String, dynamic>>());
      // Copy, edit and forward have to be off: the placeholder IS not the
      // message — forwarded, somebody else would get a placeholder.
      expect(isEnvelopeMessage(body), isTrue);
    });
  });

  group('Ausnahme', () {
    test('names the version and the reason', () {
      final e = const EnvelopeTooNewException(6);
      expect(e.version, 6);
      expect(e.toString(), contains('v6'));
      expect(e.toString(), contains('updating'));
    });
  });

  // ── Against the real decryption path ─────────────────────────────────────
  // The rest above checks helper functions. What counts here is that the path
  // REALLY distinguishes the too-new version from an ordinary failure —
  // otherwise the notice never reaches the user.
  group('the real decryption path', () {
    late MessageEncryptionService svc;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      svc = MessageEncryptionService(
          ChatKeyPairManager(const FlutterSecureStorage()));
    });

    String envelope(Object? version) => jsonEncode({
          'v': version,
          'alg': 'hybrid-kem:aes-gcm',
          'ek': base64.encode(List<int>.filled(1149, 1)),
          'msg': base64.encode(List<int>.filled(40, 2)),
        });

    // The bound is DERIVED, not written out: otherwise this test has to be
    // updated with every new version — and whoever forgets that will only
    // notice in the field that "too new" no longer holds. (With 1.27, 6 became
    // readable; this test said so immediately.)
    final zuNeu = EnvelopeVersions.maxSupported + 1;

    test('a too-new version throws the TYPED exception', () async {
      await expectLater(
        svc.decryptEnvelope(envelope(zuNeu), 'egal'),
        throwsA(isA<EnvelopeTooNewException>()
            .having((e) => e.version, 'version', zuNeu)),
      );
    });

    test('it survives the loop over all keys', () async {
      // decryptEnvelopeTryKeys otherwise packs EVERY error into a generic
      // exception. If it did that here too, the reason would never reach the
      // top — and the user would see nothing again. Against a wrong version no
      // other key helps anyway, so it is passed straight through.
      await expectLater(
        svc.decryptEnvelopeTryKeys(envelope(zuNeu + 3), ['a', 'b', 'c']),
        throwsA(isA<EnvelopeTooNewException>()),
      );
    });

    test('even without a single key', () async {
      await expectLater(
        svc.decryptEnvelopeTryKeys(envelope(zuNeu), const []),
        throwsA(isA<EnvelopeTooNewException>()),
      );
    });

    test('an unknown LOWER version stays the generic error',
        () async {
      // It is not "too new" — "please update" would be wrong here.
      await expectLater(
        svc.decryptEnvelope(envelope(2), 'egal'),
        throwsA(isA<Exception>()
            .having((e) => e is EnvelopeTooNewException, 'ist zu-neu', isFalse)),
      );
    });

    test('a missing version likewise', () async {
      await expectLater(
        svc.decryptEnvelope(envelope(null), 'egal'),
        throwsA(isA<Exception>()
            .having((e) => e is EnvelopeTooNewException, 'ist zu-neu', isFalse)),
      );
    });
  });
}
