// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The unread badge has been wrong in three different ways over time, and every
// fix added a condition to the same expression. These lock all three down.

import 'package:chattr/features/chats/unread_rules.dart';
import 'package:flutter_test/flutter_test.dart';

const me = 'user-me';
const other = 'user-other';
const chat = 'chat-1';

bool bump({
  bool isNew = true,
  String? senderId = other,
  String? currentUserId = me,
  String chatId = chat,
  String? activeChatId,
}) =>
    shouldBumpUnread(
      isNew: isNew,
      senderId: senderId,
      currentUserId: currentUserId,
      chatId: chatId,
      activeChatId: activeChatId,
    );

void main() {
  test('a new message from someone else, chat not open → bumps', () {
    expect(bump(), isTrue);
  });

  test('a re-delivered message never bumps', () {
    // Catch-up after a reconnect replays messages that were already counted.
    expect(bump(isNew: false), isFalse);
    expect(bump(isNew: false, activeChatId: 'other-chat'), isFalse);
  });

  test('your own message never bumps', () {
    // Arrives like any other on a second device, so it must be excluded here.
    expect(bump(senderId: me), isFalse);
  });

  test('a message in the chat you are looking at does not bump', () {
    expect(bump(activeChatId: chat), isFalse);
  });

  test('a message in a DIFFERENT chat still bumps while one is open', () {
    // The regression to fear: suppressing the badge everywhere once any chat
    // is open would silently hide every other conversation.
    expect(bump(activeChatId: 'some-other-chat'), isTrue);
  });

  test('a system message (no sender) still bumps', () {
    expect(bump(senderId: null), isTrue);
  });

  test('an unknown current user does not suppress a real message', () {
    // Signed-out-ish edge: never swallow a message because we lost our own id.
    expect(bump(currentUserId: null), isTrue);
  });

  group('readMarkerFor — the marker anchors to a real message, not the clock',
      () {
    final t0 = DateTime.utc(2026, 8, 12, 4);

    test('a fresh chat takes the newest message it holds', () {
      expect(
        readMarkerFor(current: null, newestLocal: t0),
        t0,
      );
    });

    test('the message in flight is NOT declared read', () {
      // The reported bug: opening the chat stamped DateTime.now(), which sits
      // ahead of a message already created on the server but not yet delivered.
      // Anchoring to the newest LOCAL message keeps the marker behind it, so it
      // still counts when it lands — matching the divider the chat draws.
      final marker = readMarkerFor(current: null, newestLocal: t0);
      final inFlight = t0.add(const Duration(seconds: 3));
      expect(inFlight.isAfter(marker!), isTrue,
          reason: 'a later-delivered message must stay countable');
    });

    test('the marker never moves backwards', () {
      // A disappearing message expiring lowers the local maximum; letting the
      // marker follow it down would resurrect the badge on everything older.
      final earlier = t0.subtract(const Duration(hours: 2));
      expect(readMarkerFor(current: t0, newestLocal: earlier), t0);
    });

    test('a chat with no messages keeps whatever marker it had', () {
      expect(readMarkerFor(current: t0, newestLocal: null), t0);
      expect(readMarkerFor(current: null, newestLocal: null), isNull);
    });

    test('a newer message moves it forward', () {
      final later = t0.add(const Duration(minutes: 5));
      expect(readMarkerFor(current: t0, newestLocal: later), later);
    });
  });
}
