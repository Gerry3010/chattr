// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-39: what other people send must not pose as Chattr, take the device
// down, or lead somewhere else than it says.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:chattr/features/media/image_guard.dart';
import 'package:chattr/features/messages/message_links.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A PNG that claims [w]×[h] in its header (CRC correct), with a tiny body.
Uint8List _pngClaiming(int w, int h) {
  final real = img.encodePng(img.Image(width: 1, height: 1));
  final bytes = Uint8List.fromList(real);
  final view = ByteData.sublistView(bytes);
  // IHDR data starts at 16: width, height (big endian).
  view.setUint32(16, w);
  view.setUint32(20, h);
  final crc = getCrc32(bytes.sublist(12, 29));
  view.setUint32(29, crc);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('C3: System-Hinweise nur ohne Absender', () {
    test('Regel', () {
      expect(isGenuineSystemSender(null), isTrue);
      expect(isGenuineSystemSender(systemId), isTrue);
      expect(isGenuineSystemSender('4f6dbce8-453f-47bf-b625-4868be77388f'),
          isFalse);
    });

    test('Zeile vom Server: als system getippt, aber mit Absender → Nachricht',
        () {
      final forged = MessageInterface.fromJson({
        'id': 'm1',
        'chat_id': 'c1',
        'sender_id': '4f6dbce8-453f-47bf-b625-4868be77388f',
        'recipient_id': 'me',
        'message_type': 'system',
        'message': 'x',
        'created_at': '2026-10-28T20:00:00Z',
      });
      expect(forged, isA<Message>());
      expect(forged.isSystemMessage, isFalse);

      final real = MessageInterface.fromJson({
        'id': 'm2',
        'chat_id': 'c1',
        'sender_id': null,
        'recipient_id': 'me',
        'message_type': 'system',
        'message': 'x',
        'created_at': '2026-10-28T20:00:00Z',
      });
      expect(real, isA<SystemMessage>());
    });
  });

  group('C5: Bildbomben werden nicht dekodiert', () {
    testWidgets('Kopf mit 20 000 × 20 000: zu groß; normales Bild: ok',
        (tester) async {
      await tester.runAsync(() async {
        expect(await encodedImageSize(_pngClaiming(20000, 20000)),
            const Size(20000, 20000));
        expect(await imageSafeToDecode(_pngClaiming(20000, 20000)), isFalse);
        expect(await imageSafeToDecode(_pngClaiming(4000, 3000)), isTrue);
        expect(await imageSafeToDecode(Uint8List.fromList(utf8.encode('kein Bild'))),
            isTrue, reason: 'Unlesbares scheitert am Decoder, wie bisher');
      });
    });
  });

  group('Links, die woanders hinführen', () {
    test('user@host und abweichender Text fragen nach', () {
      expect(
          linkNeedsConfirmation('https://bank.at@evil.example',
              Uri.parse('https://bank.at@evil.example')),
          isTrue);
      expect(linkNeedsConfirmation('bank.at', Uri.parse('https://evil.example/')),
          isTrue);
    });

    test('passender oder normaler Text öffnet direkt', () {
      expect(linkNeedsConfirmation('chattr.at', Uri.parse('https://chattr.at/blog')),
          isFalse);
      expect(linkNeedsConfirmation('www.chattr.at', Uri.parse('https://chattr.at/')),
          isFalse);
      expect(linkNeedsConfirmation('hier klicken', Uri.parse('https://chattr.at/')),
          isFalse);
      expect(linkNeedsConfirmation('Version 1.2', Uri.parse('https://chattr.at/')),
          isFalse);
    });
  });

  test('YouTube: nur ein führendes www./m. fällt weg', () {
    expect(youtubeVideoId(Uri.parse('https://m.youtube.com/watch?v=abcdef123')),
        'abcdef123');
    expect(youtubeVideoId(Uri.parse('https://youtube.cm.om/watch?v=abcdef123')),
        isNull);
  });
}
