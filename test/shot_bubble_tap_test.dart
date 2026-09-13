// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Who may tap the shot bubble? (1.27, revised 2026-08-28)
//
// At first: the recipient only. Gerry on the device: "the sender can no longer
// look at the shots he sent. should be built in too" — and rightly so, because
// his copy does not die from the look but from the 24-hour clock. At the sender
// the tap is therefore without consequence; THAT it is possible is what this
// test pins down.
//
// The special case that separates the two is the consumed shot: there is
// nothing left to open on either side then, and a tap that does nothing would
// be worse than none.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/shot_envelope.dart';
import 'package:chattr/features/media/widgets/shot_message_bubble.dart';

MediaAttachment _att() => MediaAttachment(
      mediaType: MediaType.image,
      name: 'IMG_0042.jpg',
      mime: 'image/jpeg',
      size: 12345,
      path: 'chat-1/msg-1/media-0.enc',
      keyB64: base64Encode(List<int>.filled(32, 7)),
    );

Future<int> _tippe(
  WidgetTester tester, {
  required bool isOwn,
  required ShotEnvelope shot,
  bool openedByPeer = false,
}) async {
  var getippt = 0;
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Center(
        child: ShotMessageBubble(
          shot: shot,
          isOwn: isOwn,
          openedByPeer: openedByPeer,
          onOpen: () => getippt++,
        ),
      ),
    ),
  ));
  await tester.tap(find.byType(ShotMessageBubble));
  await tester.pump();
  return getippt;
}

void main() {
  testWidgets('the recipient can open it', (tester) async {
    expect(
      await _tippe(tester, isOwn: false, shot: ShotEnvelope.of(_att())),
      1,
    );
  });

  testWidgets('the sender can look at the shot they sent', (tester) async {
    expect(
      await _tippe(tester, isOwn: true, shot: ShotEnvelope.of(_att())),
      1,
      reason: 'looking at what one sent — nothing is consumed by it',
    );
  });

  testWidgets('even after the other party has opened it', (tester) async {
    // This is exactly where his badge goes hollow — that must not take the way
    // in with it. As long as the bubble stands, so does its content for him.
    expect(
      await _tippe(
        tester,
        isOwn: true,
        shot: ShotEnvelope.of(_att()),
        openedByPeer: true,
      ),
      1,
    );
  });

  testWidgets('a consumed shot can be opened by nobody',
      (tester) async {
    final leer = ShotEnvelope.of(_att()).consumed();

    expect(await _tippe(tester, isOwn: false, shot: leer), 0);
    expect(await _tippe(tester, isOwn: true, shot: leer), 0);
  });

  testWidgets('only the sender gets the eye', (tester) async {
    // At the recipient the line underneath already says "tap to view"; at the
    // sender it says something about the other party, and without the eye there
    // would be no seeing that the bubble does anything at all.
    final auge = find.byIcon(Icons.visibility_outlined);

    await _tippe(tester, isOwn: false, shot: ShotEnvelope.of(_att()));
    expect(auge, findsNothing);

    await _tippe(tester, isOwn: true, shot: ShotEnvelope.of(_att()));
    expect(auge, findsOneWidget);

    await _tippe(tester, isOwn: true, shot: ShotEnvelope.of(_att()).consumed());
    expect(auge, findsNothing, reason: 'there is nothing left to look at');
  });
}
