// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// When does a message disappear by itself? (1.27.1)
//
// Two clocks do the same thing — the self-destruct (`expiresAt`) and the
// 24-hour afterlife of an opened shot — and two passes clear up: the full one
// on entering the chat and the five-second tick that keeps the running view
// clean.
//
// Until 1.27.1 the tick knew only `expiresAt`. A shot therefore expired only
// when one entered the chat again; if one was sitting inside it, the bubble
// stayed put. No leak (the content had long since burned), but not what the
// code promised. Since then the question stands ONCE — and these tests pin the
// answer down.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/shot_envelope.dart';
import 'package:chattr/features/messages/message_expiry.dart';
import 'package:chattr/features/messages/message_model.dart';

final _now = DateTime.utc(2026, 8, 28, 12);

MediaAttachment _att() => MediaAttachment(
      mediaType: MediaType.image,
      name: 'IMG_0042.jpg',
      mime: 'image/jpeg',
      size: 1234,
      path: 'chat-1/msg-1/media-0.enc',
      keyB64: base64Encode(List<int>.filled(32, 7)),
    );

Message _msg({
  String? content,
  DateTime? expiresAt,
  Map<String, DateTime?> readAt = const {},
}) =>
    Message(
      id: 'm1',
      chatId: 'c1',
      senderId: 'other',
      recipientId: 'me',
      decryptedContent: content ?? 'Hallo',
      createdAt: DateTime.utc(2026, 8, 20),
      expiresAt: expiresAt,
      readAt: readAt,
    );

void main() {
  final shot = ShotEnvelope.of(_att()).encode();

  test('an ordinary message never expires', () {
    expect(messageGoesAt(_msg()), isNull);
    expect(messageIsGone(_msg(), _now), isFalse);
  });

  test('self-destruct: the configured deadline applies', () {
    final m = _msg(expiresAt: _now.subtract(const Duration(minutes: 1)));
    expect(messageIsGone(m, _now), isTrue);
    expect(messageIsGone(_msg(expiresAt: _now.add(const Duration(hours: 1))),
        _now), isFalse);
  });

  test('a shot NEVER opened has no clock at all', () {
    // Important: clearing it away would mean deleting something the recipient
    // never got.
    final m = _msg(content: shot, readAt: const {'me': null});
    expect(messageGoesAt(m), isNull);
    expect(messageIsGone(m, _now), isFalse);
  });

  test('an opened shot goes 24 hours after the read mark', () {
    final marke = _now.subtract(const Duration(hours: 23));
    final m = _msg(content: shot, readAt: {'me': marke});

    expect(messageGoesAt(m), marke.add(const Duration(hours: 24)));
    expect(messageIsGone(m, _now), isFalse, reason: 'another hour to go');
    expect(messageIsGone(m, _now.add(const Duration(hours: 2))), isTrue);
  });

  test('both clocks: the earlier one wins', () {
    // A shot in a chat with self-destruct must not disappear later than
    // everything else in it.
    final marke = _now.subtract(const Duration(hours: 1));
    final frueher = _now.add(const Duration(minutes: 5));
    final m = _msg(
      content: shot,
      readAt: {'me': marke},           // + 24 h ⇒ deutlich spaeter
      expiresAt: frueher,
    );
    expect(messageGoesAt(m), frueher);

    // Und andersherum genauso.
    final m2 = _msg(
      content: shot,
      readAt: {'me': marke},
      expiresAt: _now.add(const Duration(days: 7)),
    );
    expect(messageGoesAt(m2), marke.add(const Duration(hours: 24)));
  });

  test('the earliest read mark counts, not the latest', () {
    // A group: the first to look starts the clock. Otherwise the disappearance
    // hangs on the slowest.
    final frueh = _now.subtract(const Duration(hours: 20));
    final spaet = _now.subtract(const Duration(hours: 2));
    final m = _msg(content: shot, readAt: {'a': spaet, 'b': frueh, 'c': null});

    expect(messageGoesAt(m), frueh.add(const Duration(hours: 24)));
  });
}
