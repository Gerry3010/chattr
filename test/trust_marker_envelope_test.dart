// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Regression: 1.14.0 prefixed the warn-only trust marker onto the bubble TEXT.
// Every structured envelope — media, album, invite — is recognised by parsing
// that exact string, so an unsigned sender's photo arrived as a wall of raw
// JSON instead of an image.
//
// It only reproduced for a sender WITHOUT an identity key, which is why it
// survived a full release: between two signed devices there is no marker, and
// the marker is exactly what broke the parse.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/message_signature_verifier.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/messages/message_model.dart';

void main() {
  final now = DateTime.utc(2026, 8, 7, 18);

  const mediaJson =
      '{"_chattr_media":1,"media_type":"image","name":"x.png",'
      '"mime":"image/png","size":100,'
      '"path":"chat/msg/media-0.enc","key":"a2V5","w":10,"h":20,'
      '"caption":"hallo"}';

  Message message({required String? content, String? sig}) => Message(
    id: 'm1',
    chatId: 'c1',
    senderId: 'peer',
    recipientId: 'me',
    createdAt: now,
    decryptedContent: content,
    sigStatus: sig,
  );

  group('the bubble text stays parseable', () {
    test('an unsigned media envelope is handed over untouched', () {
      final bubble = message(
        content: mediaJson,
        sig: MessageSigStatus.unsigned,
      ).toChatViewMessage();

      expect(bubble.message, mediaJson);
      expect(
        MediaAlbum.tryParse(bubble.message),
        isNotNull,
        reason: 'this parse is what decides the bubble is media at all',
      );
    });

    test('the same holds for a bad signature', () {
      final bubble = message(
        content: mediaJson,
        sig: MessageSigStatus.invalid,
      ).toChatViewMessage();

      expect(MediaAlbum.tryParse(bubble.message), isNotNull);
    });

    test('and for any future envelope type — the rule is structural', () {
      // Not a media/invite/summary envelope; still must not be prefixed.
      const someEnvelope = '{"_chattr_something_new":1,"v":2}';
      final bubble = message(
        content: someEnvelope,
        sig: MessageSigStatus.unsigned,
      ).toChatViewMessage();

      expect(bubble.message, someEnvelope);
    });
  });

  group('prose still carries the marker inline', () {
    test('unsigned prose is prefixed', () {
      final bubble = message(
        content: 'hallo',
        sig: MessageSigStatus.unsigned,
      ).toChatViewMessage();

      expect(bubble.message, contains('hallo'));
      expect(bubble.message, startsWith('ⓘ'));
    });

    test('an invalid signature uses a DIFFERENT glyph', () {
      final bubble = message(
        content: 'hallo',
        sig: MessageSigStatus.invalid,
      ).toChatViewMessage();

      expect(bubble.message, startsWith('⚠️'));
    });

    test('a good signature is not marked at all', () {
      final bubble = message(content: 'hallo').toChatViewMessage();
      expect(bubble.message, 'hallo');
      expect(sigStatusOf(bubble), isNull);
    });
  });

  group('the marker always travels in the metadata bag', () {
    test('for an envelope, where the text cannot carry it', () {
      final bubble = message(
        content: mediaJson,
        sig: MessageSigStatus.unsigned,
      ).toChatViewMessage();

      expect(sigStatusOf(bubble), MessageSigStatus.unsigned);
    });

    test('and for prose too, so the bubble never has to re-derive it', () {
      final bubble = message(
        content: 'hallo',
        sig: MessageSigStatus.invalid,
      ).toChatViewMessage();

      expect(sigStatusOf(bubble), MessageSigStatus.invalid);
    });
  });

  group('looksLikeEnvelope', () {
    test('accepts a JSON object', () {
      expect(looksLikeEnvelope('{"a":1}'), isTrue);
      expect(looksLikeEnvelope('  {"a":1}  '), isTrue);
    });

    test('rejects prose, a JSON array, and broken JSON', () {
      expect(looksLikeEnvelope('hallo'), isFalse);
      expect(looksLikeEnvelope('[1,2]'), isFalse);
      expect(looksLikeEnvelope('{kaputt'), isFalse);
      expect(looksLikeEnvelope('{"a":}'), isFalse);
      expect(looksLikeEnvelope(null), isFalse);
      expect(looksLikeEnvelope(''), isFalse);
    });

    test('a message that merely mentions braces is prose', () {
      expect(looksLikeEnvelope('schau mal: {"a":1} ist JSON'), isFalse);
    });
  });
}
