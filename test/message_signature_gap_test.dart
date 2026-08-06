// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Closes the silent-unsigned gap found on prod 2026-08-05.
//
// A device that lost its identity seed cannot sign. `_signMessage` swallows the
// IdentityKeyLockedException and returns null, and `'sig': ?signatureB64` then
// simply omits the field — so a BRAND NEW v5 envelope arrives without a
// signature. The verifier used to answer `null` for that ("nothing to check"),
// which is the same answer it gives for a genuinely pre-signature v3 message.
// Result: seven real messages travelled for two weeks with unproven authorship
// and nothing anywhere said so.
//
// These tests pin the distinction that fixes it: absent signature is legacy
// BELOW v4 and a real gap FROM v4 up.

import 'dart:async' show TimeoutException;

import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/security/key_locked_exception.dart';
import 'package:chattr/features/identity/identity_verification_controller.dart';
import 'package:chattr/features/identity/message_signature_verifier.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late MessageSignatureVerifier verifier;

  setUp(() {
    container = ProviderContainer();
    verifier = MessageSignatureVerifier(container.read(_refProbe));
  });

  tearDown(() => container.dispose());

  const context = MessageContext(
    chatId: 'c1',
    senderId: 's1',
    messageId: 'm1',
  );

  group('MessageSignatureVerifier — missing signature', () {
    test('v3 without signature stays unmarked (legacy, not a gap)', () async {
      final status = await verifier.verify(
        context: context,
        plaintext: 'hallo',
        signatureB64: null,
        envelopeVersion: 3,
      );
      expect(status, isNull);
    });

    test('v2 without signature stays unmarked too', () async {
      expect(
        await verifier.verify(
          context: context,
          plaintext: 'hallo',
          signatureB64: null,
          envelopeVersion: 2,
        ),
        isNull,
      );
    });

    test('v4 without signature is reported as unsigned', () async {
      final status = await verifier.verify(
        context: context,
        plaintext: 'hallo',
        signatureB64: null,
        envelopeVersion: 4,
      );
      expect(status, MessageSigStatus.unsigned);
    });

    test('v5 without signature is reported as unsigned', () async {
      // The exact case observed on prod: newest envelope, no signature.
      expect(
        await verifier.verify(
          context: context,
          plaintext: 'hallo',
          signatureB64: null,
          envelopeVersion: 5,
        ),
        MessageSigStatus.unsigned,
      );
    });

    test('an EMPTY signature counts as missing, not as present', () async {
      expect(
        await verifier.verify(
          context: context,
          plaintext: 'hallo',
          signatureB64: '',
          envelopeVersion: 5,
        ),
        MessageSigStatus.unsigned,
      );
    });

    test('unsigned is a distinct value from invalid', () {
      // They must never collapse: "wrong signature" is a forgery suspicion,
      // "no signature" is a broken sender. The UI shows different symbols.
      expect(MessageSigStatus.unsigned, isNot(MessageSigStatus.invalid));
      expect(MessageSigStatus.unsigned, isNot(MessageSigStatus.valid));
    });
  });

  group('Bubble rendering', () {
    Message message(String? sigStatus) => Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 's1',
          recipientId: 'r1',
          createdAt: DateTime.utc(2026, 8, 5),
          decryptedContent: 'Guten Morgen',
          sigStatus: sigStatus,
        );

    test('an unsigned message carries a marker and keeps its text', () {
      final bubble = message(MessageSigStatus.unsigned).toChatViewMessage();
      expect(bubble.message, contains('Guten Morgen'));
      expect(bubble.message, startsWith('ⓘ'));
    });

    test('an invalid signature keeps its own, louder marker', () {
      final bubble = message(MessageSigStatus.invalid).toChatViewMessage();
      expect(bubble.message, contains('Guten Morgen'));
      expect(bubble.message, startsWith('⚠️'));
    });

    test('the two markers differ — one symbol for both trains people to '
        'ignore both', () {
      final unsigned = message(MessageSigStatus.unsigned).toChatViewMessage();
      final invalid = message(MessageSigStatus.invalid).toChatViewMessage();
      expect(unsigned.message, isNot(invalid.message));
    });

    test('a signed-and-valid message gets no marker at all', () {
      final bubble = message(MessageSigStatus.valid).toChatViewMessage();
      expect(bubble.message, 'Guten Morgen');
    });

    test('an unmarked (v3) message gets no marker either', () {
      expect(message(null).toChatViewMessage().message, 'Guten Morgen');
    });
  });

  _remedyTests();
}

/// Hands out the container's own Ref so the verifier can be built exactly as
/// the app builds it. The missing-signature branch returns before any read, so
/// no provider overrides are needed for these cases.
final _refProbe = Provider<Ref>((ref) => ref);

/// The second half of the fix: a device whose seed is GONE must be offered the
/// explicit re-mint, and a device whose key is merely unpublished must NOT be
/// — one flips every peer's safety number, the other is free. The old UI got
/// this wrong in the first direction and the button failed forever.
void _remedyTests() {
  group('identityRemedyFor', () {
    test('no error → nothing to offer on our side', () {
      expect(identityRemedyFor(null), IdentityRemedy.none);
    });

    test('lost seed (IdentityKeyLockedException) → offer re-mint', () {
      expect(
        identityRemedyFor(IdentityKeyLockedException(Exception('keystore'))),
        IdentityRemedy.regenerate,
      );
    });

    test('any other failure → offer publish, never a re-mint', () {
      // A timeout or an offline socket must not cost the user their identity.
      expect(
        identityRemedyFor(TimeoutException('offline')),
        IdentityRemedy.publish,
      );
      expect(identityRemedyFor(StateError('boom')), IdentityRemedy.publish);
    });
  });
}
