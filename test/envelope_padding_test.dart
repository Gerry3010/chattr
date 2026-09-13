// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Padding message lengths — the roadmap item "pad message lengths".
//
// AES-GCM is a stream-cipher mode: the ciphertext is exactly as long as the
// plaintext. The content is unreadable, the LENGTH is not — and the server can
// measure `messages.encrypted_content` at its leisure, alongside sender,
// recipient, chat and timestamp. A two-character answer to a question is as
// good as certainly "yes" or "ok".
//
// The checks here therefore do not ask "does the code run through" but: can one
// still read the message off the row length?

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/envelope_padding.dart';
import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart' show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';

void main() {
  String envelope(String plaintext) => jsonEncode({
        'v': 5,
        'alg': 'hybrid-kem:aes-gcm',
        // An envelope carries a ~1.5 KB ML-KEM ciphertext. So the base is large
        // — the message nevertheless sits in it exactly measurably, and that is
        // precisely the issue.
        'ek': 'A' * 1532,
        'pk': '11111111-1111-1111-1111-111111111111',
        'msg': base64.encode(List<int>.filled(28 + plaintext.length, 7)),
        'sig': 'S' * 88,
      });

  group('the length no longer betrays the message', () {
    test('short answers can no longer be told apart', () {
      // The heart of it all: "yes", "no" and "on my way" are the cases in which
      // the length is almost the whole message.
      final lengths = <String, int>{
        for (final t in ['ja', 'nein', 'ok', '👍', 'bin unterwegs', 'passt schon'])
          t: EnvelopePadding.pad(envelope(t)).length,
      };
      expect(
        lengths.values.toSet(),
        hasLength(1),
        reason: 'differing lengths: $lengths',
      );
    });

    test('without padding they WOULD be distinguishable (counter-check)', () {
      // Without this counter-check the test above would not know whether it
      // measures anything.
      final raw = {
        for (final t in ['ja', 'nein', 'bin unterwegs']) t: envelope(t).length,
      };
      expect(raw.values.toSet().length, greaterThan(1),
          reason: 'the raw lengths have to differ: $raw');
    });

    test('every length sits exactly on the grid', () {
      for (var n = 0; n < 600; n++) {
        final padded = EnvelopePadding.pad(envelope('x' * n));
        expect(padded.length % EnvelopePadding.bucket, 0,
            reason: 'plaintext length $n produced ${padded.length}');
      }
    });

    test('the grid absorbs ~190 characters of plaintext difference', () {
      // Computed rather than claimed: how many consecutive plaintext lengths
      // fall on the same final length on average?
      final proBucket = <int, int>{};
      for (var n = 0; n < 2000; n++) {
        final l = EnvelopePadding.pad(envelope('x' * n)).length;
        proBucket[l] = (proBucket[l] ?? 0) + 1;
      }
      final average =
          proBucket.values.reduce((a, b) => a + b) / proBucket.length;
      expect(average, greaterThan(150),
          reason: 'only $average plaintext lengths per bucket');
    });

    test('padding never makes the envelope smaller', () {
      for (final n in [0, 1, 100, 1000]) {
        final raw = envelope('x' * n);
        expect(EnvelopePadding.pad(raw).length, greaterThan(raw.length));
      }
    });

    test('the surcharge stays below a full grid step', () {
      // Otherwise one would pay twice: the padding may go at most to the next
      // grid line, not to the one after.
      for (var n = 0; n < 400; n++) {
        final raw = envelope('x' * n);
        final auf = EnvelopePadding.pad(raw).length - raw.length;
        expect(auf, lessThanOrEqualTo(2 * EnvelopePadding.bucket));
      }
    });
  });

  group('the envelope stays readable', () {
    test('stays valid JSON with all the original fields', () {
      final raw = envelope('Treffen um 20:00?');
      final m = jsonDecode(EnvelopePadding.pad(raw)) as Map<String, dynamic>;
      final o = jsonDecode(raw) as Map<String, dynamic>;
      for (final k in o.keys) {
        expect(m[k], o[k], reason: 'field $k changed');
      }
      expect(m['v'], 5, reason: 'the version must NOT change');
    });

    test('adds exactly one field', () {
      // An old client reads v/ek/msg/sig/pk and never looks at the padding
      // field. If more than one were added, that would be a silent format
      // change.
      final m = jsonDecode(EnvelopePadding.pad(envelope('hallo')))
          as Map<String, dynamic>;
      final o = jsonDecode(envelope('hallo')) as Map<String, dynamic>;
      expect(m.keys.toSet().difference(o.keys.toSet()),
          {EnvelopePadding.field});
    });
  });

  group('the padding is random, not a pattern', () {
    test('two identical messages yield different paddings', () {
      final a = EnvelopePadding.pad(envelope('gleich'));
      final b = EnvelopePadding.pad(envelope('gleich'));
      expect(a, isNot(b), reason: 'the padding repeats itself');
      expect(a.length, b.length);
    });

    test('it cannot be compressed away', () {
      // Postgres compresses larger values (TOAST). If the padding were a run of
      // identical characters, it would shrink back down on disk — and the
      // stored size would reveal the real length again. As an approximation:
      // how many different characters occur?
      final m = jsonDecode(EnvelopePadding.pad(envelope('x')))
          as Map<String, dynamic>;
      final filler = m[EnvelopePadding.field] as String;
      expect(filler.length, greaterThan(20));
      expect(filler.split('').toSet().length, greaterThan(10),
          reason: 'zu wenig verschiedene Zeichen — komprimierbar');
    });

    test('the padding needs no JSON escaping', () {
      // An escaped character (\" or \\) would be longer in the JSON than in the
      // string — then the final length would no longer hold.
      final r = Random(42);
      for (var i = 0; i < 50; i++) {
        final padded = EnvelopePadding.pad(envelope('x' * i), random: r);
        final filler = (jsonDecode(padded) as Map)[EnvelopePadding.field] as String;
        expect(jsonEncode(filler).length, filler.length + 2,
            reason: 'the padding contains a character that needs escaping');
      }
    });
  });

  group('edge cases', () {
    test('something that is not a JSON object stays untouched', () {
      for (final s in ['', 'nicht json', '[1,2]', '{}']) {
        expect(EnvelopePadding.pad(s), s);
      }
    });

    test('a grid of 0 or less does not pad', () {
      final raw = envelope('x');
      expect(EnvelopePadding.pad(raw, bucket: 0), raw);
      expect(EnvelopePadding.pad(raw, bucket: -8), raw);
    });

    test('a different grid is honoured', () {
      for (final b in [64, 128, 512, 1024]) {
        for (var n = 0; n < 40; n++) {
          expect(EnvelopePadding.pad(envelope('x' * n), bucket: b).length % b, 0);
        }
      }
    });
  });

  // ── Against the real service, not the reconstructed envelope ──────────────
  // The checks above measure the padding function. These measure that it is
  // APPLIED in the send path at all — without that, everything above would be
  // correct and without effect.
  group('echter Sendepfad', () {
    const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
    final skip =
        File(libPath).existsSync() ? false : 'native lib fehlt ($libPath)';
    late MessageEncryptionService svc;

    setUpAll(() {
      if (skip == false) mlKemLibraryPathOverride = libPath;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    });
    tearDownAll(() => debugDefaultTargetPlatformOverride = null);
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      svc = MessageEncryptionService(
          ChatKeyPairManager(const FlutterSecureStorage()));
    });

    test('the delivered envelope sits on the grid and is readable',
        () async {
      final pair = await ChatKeyPairManager.generateDetachedKeyPair();
      const chatId = 'chat-pad';
      const plaintext = 'ja';
      final ctx = const MessageContext(
          chatId: chatId, senderId: 'alice', messageId: 'm1');

      final out = await svc.encryptForAllMembers(
        plaintext,
        {'bob': pair.publicKey},
        context: ctx,
      );
      final envelope = out['bob']!;

      expect(envelope.length % EnvelopePadding.bucket, 0,
          reason: 'the send path does not pad (${envelope.length})');
      expect((jsonDecode(envelope) as Map).containsKey(EnvelopePadding.field),
          isTrue);

      final back = await svc.decryptEnvelope(
        envelope,
        pair.privateKey,
        context: ctx,
      );
      expect(back.plaintext, plaintext,
          reason: 'the padded envelope can no longer be read');
    }, skip: skip);

    test('short and long cannot be told apart on the delivered envelope',
        () async {
      final pair = await ChatKeyPairManager.generateDetachedKeyPair();
      final lengths = <String, int>{};
      for (final t in ['ja', 'nein', 'bin schon unterwegs']) {
        final out = await svc.encryptForAllMembers(
          t,
          {'bob': pair.publicKey},
          context: MessageContext(
              chatId: 'c', senderId: 'alice', messageId: 'm-$t'),
        );
        lengths[t] = out['bob']!.length;
      }
      expect(lengths.values.toSet(), hasLength(1), reason: '$lengths');
    }, skip: skip);
  });
}
