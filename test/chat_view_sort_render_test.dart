// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Runtime render-order guard for the scroll-up pagination fix. The chat keeps
// two stores in sync: our (correctly ordered) Riverpod list and chatview's
// `ChatController.initialMessageList`. The bridge only has an append-to-tail
// path (`addMessage`), so a scrolled-up OLDER page used to land among the
// newest messages. Fix = render by `createdAt` (`sortEnable` + a stable
// `messageSorter`) so insertion order stops mattering. This test drives the
// REAL chatview widget with deliberately-scrambled insertion and asserts the
// on-screen vertical order is chronological.

import 'package:chattr/features/messages/message_ordering.dart';
import 'package:chatview/chatview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 18, 9);
  String body(int i) => 'body-${i.toString().padLeft(2, '0')}';
  Message msg(int i) => Message(
        id: 'm${i.toString().padLeft(2, '0')}',
        message: body(i),
        createdAt: t0.add(Duration(minutes: i)),
        sentBy: 'other',
      );

  Widget harness({required bool sortEnable}) {
    final controller = ChatController(
      initialMessageList: [],
      scrollController: ScrollController(),
      currentUser: const ChatUser(id: 'me', name: 'Me'),
      otherUsers: const [ChatUser(id: 'other', name: 'Other')],
    );
    // Insertion order mimics the bug exactly: the NEWEST half arrives first,
    // then the OLDER page is appended to the tail (chatview.addMessage always
    // appends) — i.e. 3,4,5 then 0,1,2.
    for (final i in [3, 4, 5, 0, 1, 2]) {
      controller.addMessage(msg(i));
    }
    return MaterialApp(
      home: Scaffold(
        body: ChatView(
          chatController: controller,
          chatViewState: ChatViewState.hasMessages,
          featureActiveConfig: const FeatureActiveConfig(
            enablePagination: true,
          ),
          chatBackgroundConfig: ChatBackgroundConfiguration(
            sortEnable: sortEnable,
            messageSorter: (a, b) =>
                compareMessagesNewestFirst(a.createdAt, a.id, b.createdAt, b.id),
          ),
          onSendTap: (_, _, _) {},
          sendMessageBuilder: (_) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  testWidgets(
    'sortEnable+messageSorter renders chronologically despite scrambled insertion',
    (tester) async {
      await tester.pumpWidget(harness(sortEnable: true));
      await tester.pump(const Duration(milliseconds: 300));

      for (var i = 0; i < 6; i++) {
        expect(find.text(body(i)), findsOneWidget, reason: '${body(i)} rendered');
      }

      // ListView is reversed (index 0 = bottom = newest), so the oldest message
      // sits at the top (smallest dy) and each newer one strictly below it.
      double dy(int i) => tester.getTopLeft(find.text(body(i))).dy;
      for (var i = 0; i < 5; i++) {
        expect(
          dy(i),
          lessThan(dy(i + 1)),
          reason: '${body(i)} must render above ${body(i + 1)}',
        );
      }
    },
  );

  testWidgets(
    'without sortEnable the scrambled insertion order leaks through (guards the lever)',
    (tester) async {
      await tester.pumpWidget(harness(sortEnable: false));
      await tester.pump(const Duration(milliseconds: 300));

      // Pure insertion order [3,4,5,0,1,2] rendered reversed: index 0 (msg 3) at
      // the bottom. So the older messages 0,1,2 (appended last) sit BELOW the
      // newer 3,4,5 — the exact jumble. Concretely, the oldest message (0)
      // must NOT be at the top: msg 3 renders above msg 0.
      expect(
        tester.getTopLeft(find.text(body(3))).dy,
        lessThan(tester.getTopLeft(find.text(body(0))).dy),
        reason: 'insertion order puts newer msg 3 above older msg 0 (the bug)',
      );
    },
  );
}
