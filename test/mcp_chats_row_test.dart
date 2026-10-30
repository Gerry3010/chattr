// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The agent-chats row is hidden behind a pull-down gesture so a chatty agent
// cannot clutter the chat list. That left a hole: the app-icon badge counts
// agent chats like any other, so an unread agent message showed up as a number
// on the icon with nothing to explain it anywhere in the list.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/screens/chat/chat_list_screen.dart';

void main() {
  final base = DateTime.utc(2026, 8, 7, 1);

  Chat mcpChat(String id, {int unread = 0}) => Chat(
    id: id,
    createdAt: base,
    isMcp: true,
    unreadCount: unread,
  );

  group('mcpUnreadTotal', () {
    test('sums across agent chats', () {
      expect(
        mcpUnreadTotal([mcpChat('a', unread: 2), mcpChat('b', unread: 5)]),
        7,
      );
    });

    test('is zero for no chats and for read chats', () {
      expect(mcpUnreadTotal(const []), 0);
      expect(mcpUnreadTotal([mcpChat('a'), mcpChat('b')]), 0);
    });
  });

  group('shouldShowMcpRow', () {
    test('hidden by default — that is the point of the row', () {
      expect(
        shouldShowMcpRow(
          mcpChatCount: 2,
          mcpUnread: 0,
          revealedByGesture: false,
        ),
        isFalse,
      );
    });

    test('the pull-down gesture still reveals it with nothing unread', () {
      expect(
        shouldShowMcpRow(
          mcpChatCount: 2,
          mcpUnread: 0,
          revealedByGesture: true,
        ),
        isTrue,
      );
    });

    test('unread beats hidden — otherwise the icon badge has no source', () {
      expect(
        shouldShowMcpRow(
          mcpChatCount: 1,
          mcpUnread: 1,
          revealedByGesture: false,
        ),
        isTrue,
      );
    });

    test('it hides itself again once read', () {
      // Reading the agent chat sets its local read marker, the count drops to
      // zero, and the row goes back into hiding — no manual dismissal.
      expect(
        shouldShowMcpRow(
          mcpChatCount: 1,
          mcpUnread: 0,
          revealedByGesture: false,
        ),
        isFalse,
      );
    });

    test('never shown without agent chats, whatever the gesture did', () {
      expect(
        shouldShowMcpRow(
          mcpChatCount: 0,
          mcpUnread: 0,
          revealedByGesture: true,
        ),
        isFalse,
      );
    });
  });

  // Since 1.26.2 the row can be cleared away again with the same gesture
  // (Gerry, 2026-08-26). Turning a one-off reveal into a toggle is the point at
  // which the stream of reports becomes a problem: ONE drag produces dozens of
  // reports, and whoever reacts to every one flips several times per swipe —
  // that would show up as "the gesture sometimes does nothing", not as "it does
  // too much". So the latch is under test here and not merely in a comment.
  group('OverdragGesture', () {
    test('fires exactly once per drag, not once per report', () {
      final geste = OverdragGesture();
      expect(geste.fires(pastTop: true), isTrue);
      for (var i = 0; i < 30; i++) {
        expect(geste.fires(pastTop: true), isFalse,
            reason: 'Meldung ${i + 2} desselben Zuges');
      }
    });

    test('the next drag may trigger again', () {
      final geste = OverdragGesture();
      expect(geste.fires(pastTop: true), isTrue);
      geste.ended();
      expect(geste.fires(pastTop: true), isTrue);
    });

    test('ordinary scrolling triggers nothing', () {
      final geste = OverdragGesture();
      for (var i = 0; i < 10; i++) {
        expect(geste.fires(pastTop: false), isFalse);
      }
      expect(geste.latched, isFalse);
    });

    test('a report within the bounds does NOT unlatch', () {
      // Android holds the position at the boundary while overscrolling and
      // reports the excess separately. If an in-bounds report in between
      // released the latch, the row would flip a second time in the same drag —
      // and end up back where it was.
      final geste = OverdragGesture();
      expect(geste.fires(pastTop: true), isTrue);
      expect(geste.fires(pastTop: false), isFalse);
      expect(geste.fires(pastTop: true), isFalse,
          reason: 'only a ScrollEndNotification may unlatch');
      geste.ended();
      expect(geste.fires(pastTop: true), isTrue);
    });

    test('two drags give open and closed again', () {
      final geste = OverdragGesture();
      var sichtbar = false;
      for (var zug = 0; zug < 2; zug++) {
        for (var i = 0; i < 12; i++) {
          if (geste.fires(pastTop: true)) sichtbar = !sichtbar;
        }
        geste.ended();
        expect(sichtbar, zug == 0, reason: 'nach Zug ${zug + 1}');
      }
    });
  });
}
