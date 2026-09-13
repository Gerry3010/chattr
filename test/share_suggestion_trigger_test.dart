// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// When a chat is donated to the share menu's suggestion row.
//
// Reported on 2026-08-19: chats from other apps ranked ahead of Chattr, although
// far less was written in them. The cause — donation happened ONLY on sending,
// but the system ranks by interactions, and other messengers donate in both
// directions. So Chattr showed half the conversation.
//
// The trigger is now additionally the OPENING of a chat with something unread.
// This rule has three edges, and every single one is a deliberate decision —
// which is why it stands here as a list instead of in somebody's head:
//
//   * receiving alone does NOT donate (otherwise strangers and spam land in the
//     system store without one ever having looked),
//   * a quiet chat one merely clicks through does NOT donate (that would be
//     noise, not engagement),
//   * and donation happens per READ, not per message — otherwise whoever sends
//     twenty messages in a row overtakes a chat with real back and forth.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The decision as it stands in the controller: read `_hasUnread()` BEFORE the
/// reset, then donate exactly once.
int donationsForOpen({required int unreadBeforeOpen}) =>
    unreadBeforeOpen > 0 ? 1 : 0;

void main() {
  test('opening with something unread donates exactly once', () {
    expect(donationsForOpen(unreadBeforeOpen: 1), 1);
  });

  test('per read, not per message', () {
    // Twenty messages in a row are ONE engagement, not twentyfold.
    expect(donationsForOpen(unreadBeforeOpen: 20), 1,
        reason: 'otherwise a prolific sender overtakes real back and forth');
  });

  test('a quiet chat does not donate when clicked through', () {
    expect(donationsForOpen(unreadBeforeOpen: 0), 0,
        reason: 'clicking through is not engagement');
  });

  test('opening repeatedly without anything new donates only the first time', () {
    // After the first opening the counter is reset — the further openings see 0
    // and therefore donate no more.
    var donated = donationsForOpen(unreadBeforeOpen: 3);
    donated += donationsForOpen(unreadBeforeOpen: 0);
    donated += donationsForOpen(unreadBeforeOpen: 0);
    expect(donated, 1);
  });

  // The order is the silent killer: if `_hasUnread()` is moved BEHIND the
  // reset, it returns false forever and nothing is ever donated again — without
  // any test going red and without anybody noticing, because a missing
  // suggestion row looks like "the system just doesn't want to". Hence pinned
  // down here in the source.
  test('the unread state is read BEFORE the reset', () {
    final src = File('lib/features/messages/messages_controller.dart')
        .readAsStringSync();
    final lines = src.split('\n');

    final resetIdx = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains('resetUnreadCount(chatId)')) i,
    ];
    expect(resetIdx, hasLength(2),
        reason: 'the call sites have changed — check the rule again');

    for (final i in resetIdx) {
      final davor = lines.sublist((i - 6).clamp(0, i), i).join('\n');
      expect(davor, contains('_hasUnread()'),
          reason: 'bei Zeile ${i + 1} fehlt der Ungelesen-Stand VOR dem Reset');
    }

    // And afterwards something really has to be donated.
    expect(src, contains('if (hadUnread) unawaited(_donateShareSuggestion());'));
  });
}
