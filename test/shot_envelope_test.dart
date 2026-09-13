// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Shots — pictures and videos that can be opened exactly once (1.27).
//
// Two guarantees carry the promise, and both are pinned down here:
//
//   1. **A shot must NEVER pass as ordinary media.** The attachment sits in an
//      envelope of its own so that `MediaAlbum.tryParse` does not find it. If it
//      did, every older client would display the picture as a normal photo — as
//      often as one liked, and nobody would notice a thing.
//   2. **Consumed means keyless.** The burn is not the deletion of the file (a
//      recipient may not do that at all) but the throwing away of the media key
//      from the local copy.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/envelope_version.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/shot_envelope.dart';

MediaAttachment _att({MediaType kind = MediaType.image}) => MediaAttachment(
      mediaType: kind,
      name: 'IMG_0042.jpg',
      mime: 'image/jpeg',
      size: 12345,
      path: 'chat-1/msg-1/media-0.enc',
      keyB64: base64Encode(List<int>.filled(32, 7)),
      width: 1600,
      height: 900,
    );

void main() {
  group('Umschlag', () {
    test('a shot does NOT parse as media', () {
      final body = ShotEnvelope.of(_att()).encode();

      expect(MediaAlbum.tryParse(body), isNull,
          reason: 'otherwise an older client shows the picture quite normally');
      expect(MediaAttachment.tryParse(body), isNull);
      expect(body.contains(MediaAttachment.marker), isFalse,
          reason: 'the media marker must appear nowhere in the body');
    });

    test('there and back: attachment and type survive', () {
      final shot = ShotEnvelope.of(_att(kind: MediaType.video));
      final back = ShotEnvelope.tryParse(shot.encode())!;

      expect(back.kind, MediaType.video);
      expect(back.isConsumed, isFalse);
      expect(back.attachment!.path, 'chat-1/msg-1/media-0.enc');
      expect(back.attachment!.keyB64, shot.attachment!.keyB64);
    });

    test('consumed: the key is gone, the bubble stays', () {
      final shot = ShotEnvelope.of(_att(kind: MediaType.video));
      final consumed = shot.consumed();
      final body = consumed.encode();

      expect(consumed.isConsumed, isTrue);
      expect(body.contains(shot.attachment!.keyB64), isFalse,
          reason: 'THAT is the burn — without the key nobody can open it any more');
      expect(body.contains('chat-1/msg-1/media-0.enc'), isFalse);
      // The type stays: the consumed bubble should go on carrying a video's
      // colour and icon.
      expect(ShotEnvelope.tryParse(body)!.kind, MediaType.video);
    });

    test('an unreadable attachment counts as consumed, not as openable', () {
      // The safe direction: better a bubble that can no longer be opened than a
      // half-parsed one that can after all.
      final body = jsonEncode({
        ShotEnvelope.marker: 1,
        'kind': 'image',
        'a': {'media_type': 'image'}, // ohne path/key
      });
      final shot = ShotEnvelope.tryParse(body);

      expect(shot, isNotNull);
      expect(shot!.isConsumed, isTrue);
    });

    test('foreign bodies are not read as a shot by mistake', () {
      expect(ShotEnvelope.tryParse(null), isNull);
      expect(ShotEnvelope.tryParse(''), isNull);
      expect(ShotEnvelope.tryParse('ganz normaler Text'), isNull);
      expect(ShotEnvelope.tryParse('{"kaputt":'), isNull);
      // A text that happens to contain the marker is not a shot.
      expect(ShotEnvelope.tryParse('schau mal: _chattr_shot'), isNull);
      expect(ShotEnvelope.tryParse(_att().encode()), isNull);
    });

    test('isShotMessage is the short form for every lock', () {
      expect(isShotMessage(ShotEnvelope.of(_att()).encode()), isTrue);
      expect(isShotMessage(_att().encode()), isFalse);
      expect(isShotMessage('Hallo'), isFalse);
    });
  });

  group('Umschlag-Version 6', () {
    test('6 is readable and is the new upper bound', () {
      expect(EnvelopeVersions.supported.contains(6), isTrue);
      expect(EnvelopeVersions.maxSupported, 6,
          reason: 'it is derived, never written beside it by hand');
    });

    test('7 counts as too new — a card instead of silence', () {
      expect(EnvelopeVersions.isTooNew(7), isTrue);
      expect(EnvelopeVersions.isTooNew(6), isFalse);
    });
  });

  group('when the bubble disappears', () {
    final att = _att();

    test('unopened, nothing expires', () {
      expect(
        shotDisappearsAt(ShotEnvelope.of(att).encode(), const {'a': null}),
        isNull,
      );
    });

    test('opened: a day later, the same clock on both sides', () {
      final opened = DateTime.utc(2026, 8, 28, 12);
      final end = shotDisappearsAt(
        ShotEnvelope.of(att).encode(),
        {'empfaenger': opened},
      );
      expect(end, opened.add(kShotAfterlife));
    });

    test('in a group the FIRST to open counts', () {
      final frueh = DateTime.utc(2026, 8, 28, 12);
      final spaet = DateTime.utc(2026, 8, 28, 18);
      final end = shotDisappearsAt(
        ShotEnvelope.of(att).encode(),
        {'a': spaet, 'b': frueh, 'c': null},
      );
      expect(end, frueh.add(kShotAfterlife));
    });

    test('an ordinary message never expires through this', () {
      expect(
        shotDisappearsAt('Hallo', {'a': DateTime.utc(2020)}),
        isNull,
      );
      expect(
        shotDisappearsAt(
            att.encode(), {'a': DateTime.utc(2020)}),
        isNull,
      );
    });
  });
}
