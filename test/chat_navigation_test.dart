// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The jump to a message. Reported on 2026-08-23: a tap in the favorites pushed
// a SECOND ChatView onto the same chat — visible in the doubled back
// navigation, noticeable in that the jump ended up stuck (both instances listen
// to the same notifier, and the fork's jump run carries a single-scan token).
//
// What is checked is the bookkeeping the decision rests on: only when it is
// known that the chat is already on the stack may one pop back instead of
// pushing. If it is wrong, `popUntil` clears down to the root.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/navigation/chat_navigation.dart';

void main() {
  setUp(() {
    OpenChats.leave('a');
    OpenChats.leave('b');
  });

  test('the route name hangs on the chat, not on the message', () {
    expect(chatRouteName('a'), 'chat/a');
    expect(chatRouteName('a'), isNot(chatRouteName('b')));
  });

  test('an unknown chat counts as not open', () {
    expect(OpenChats.isOpen('a'), isFalse);
  });

  test('entering and leaving keep the books', () {
    OpenChats.enter('a');
    expect(OpenChats.isOpen('a'), isTrue);
    expect(OpenChats.isOpen('b'), isFalse);

    OpenChats.leave('a');
    expect(OpenChats.isOpen('a'), isFalse);
  });

  test('entered twice, left once: then closed', () {
    // A set, not a counter — after the fix the same chat never lies on the
    // stack twice, and a counter would turn a leak into a silent trap: "open"
    // although no route is left means clearing down to the root.
    OpenChats.enter('a');
    OpenChats.enter('a');
    OpenChats.leave('a');
    expect(OpenChats.isOpen('a'), isFalse);
  });

  // Filed afterwards on 2026-08-23: the jump worked "basically", but not to OLD
  // favorites. The reason: `highlightMessage` is a SILENT failure when the
  // message is not in the loaded window — and with an already open chat nobody
  // paged back. The fork says so itself: that is the host's job. So what is
  // checked is exactly the run that did not exist before.

  test('if the message is already there it pulses at once — without paging',
      () async {
    var loaded = 0, gepulst = 0;
    final ok = await pageUntilLoaded(
      isLoaded: () => true,
      gibtNochMehr: () => true,
      loadMore: () async => loaded++,
      pulsen: () => gepulst++,
      atemzug: () async {},
    );
    expect(ok, isTrue);
    expect(gepulst, 1);
    expect(loaded, 0, reason: 'kein Grund, Geschichte nachzuladen');
  });

  test('an old favorite: it pages back until it turns up', () async {
    var pages = 0, gepulst = 0;
    final ok = await pageUntilLoaded(
      isLoaded: () => pages >= 3,
      gibtNochMehr: () => true,
      loadMore: () async => pages++,
      pulsen: () => gepulst++,
      atemzug: () async {},
    );
    expect(ok, isTrue);
    expect(pages, 3);
    expect(gepulst, 1);
  });

  test('history at an end and nothing found: stop quietly, do not pulse',
      () async {
    var gepulst = 0;
    final ok = await pageUntilLoaded(
      isLoaded: () => false,
      gibtNochMehr: () => false,
      loadMore: () async {},
      pulsen: () => gepulst++,
      atemzug: () async {},
    );
    expect(ok, isFalse);
    expect(gepulst, 0);
  });

  test('an endless history does not run endlessly', () async {
    // Without an upper bound a destination that does not exist would page
    // forever — on a phone that means: battery flat, list full, never an error.
    var pages = 0;
    final ok = await pageUntilLoaded(
      isLoaded: () => false,
      gibtNochMehr: () => true,
      loadMore: () async => pages++,
      pulsen: () {},
      pages: 5,
      atemzug: () async {},
    );
    expect(ok, isFalse);
    expect(pages, 5);
  });
}
