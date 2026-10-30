// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The search IN the chat: a hit has to lead to the message.
//
// Reported by Gerry on 2026-08-30: "the search-in-chat function doesn't let you
// click search results → you only see the short preview but you can't jump to
// the message." The cause was as small as the effect was large: the `ListTile`
// had no `onTap`. What was built was a preview of something there was no route
// to.
//
// So what is pinned down here is exactly the link that was missing — that the
// tap arrives, WITH which message, and that the search closes in the process
// (otherwise it would lie over the chat that was just jumped into). The jump
// itself belongs to `openChatAtMessage` and is checked there.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_helpers.dart';

import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/screens/chat/components/message_search_delegate.dart';

/// The hit rows show an avatar that hangs on the profile cache, which in turn
/// hangs on the real Supabase client — without an override that throws at build
/// time already. This is about the tap, not about the picture.
final _withoutServer = [
  // Without this every row fetches its profile and its avatar image from the
  // server. What counts here is the tap, not the picture — the circle falls
  // back to the initial, as it does in the field while nothing is loaded. A
  // real `SupabaseClient` would be the wrong substitute: it starts timers of
  // its own, and those outlive the widget tree, which the test harness rightly
  // insists on.
  profileProvider.overrideWith((ref, userId) => null),
  avatarSignedUrlProvider.overrideWith((ref, args) => null),
];

Message _msg(String id, String text) => Message(
      id: id,
      chatId: 'c1',
      senderId: 'other',
      recipientId: 'me',
      encryptedContent: 'zzz',
      createdAt: DateTime.utc(2026, 8, 30, 12),
    )..decryptedContent = text;

/// Builds the search and returns which message id was tapped.
Future<List<String>> _searchAndTap(
  WidgetTester tester, {
  required List<Message> matches,
  required String input,
  bool tippen = true,
}) async {
  final gesprungen = <String>[];
  await tester.pumpWidget(ProviderScope(
    overrides: _withoutServer,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showSearch<void>(
              context: c,
              delegate: MessageSearchDelegate(
                search: (_) async => matches,
                usernames: const {'other': 'Bob'},
                currentUserId: 'me',
                onJump: gesprungen.add,
              ),
            ),
            child: const Text('suchen'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('suchen'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField), input);
  await tester.pumpAndSettle();

  if (tippen) {
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
  }
  return gesprungen;
}

void main() {
  testWidgets('a hit leads to ITS message, not to just any',
      (tester) async {
    final gesprungen = await _searchAndTap(
      tester,
      matches: [_msg('m1', 'erster Treffer'), _msg('m2', 'zweiter Treffer')],
      input: 'Treffer',
    );
    expect(gesprungen, ['m1']);
  });

  testWidgets('the second hit jumps to the second one', (tester) async {
    final gesprungen = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: _withoutServer,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showSearch<void>(
                context: c,
                delegate: MessageSearchDelegate(
                  search: (_) async =>
                      [_msg('m1', 'eins'), _msg('m2', 'zwei')],
                  usernames: const {'other': 'Bob'},
                  currentUserId: 'me',
                  onJump: gesprungen.add,
                ),
              ),
              child: const Text('suchen'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('suchen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'e');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).at(1));
    await tester.pumpAndSettle();
    expect(gesprungen, ['m2']);
  });

  testWidgets('the search closes on jumping', (tester) async {
    await _searchAndTap(
      tester,
      matches: [_msg('m1', 'irgendwas')],
      input: 'irgend',
    );
    // The search field is gone — otherwise the search would lie over the chat
    // that was just jumped into.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('suchen'), findsOneWidget);
  });

  testWidgets('every hit is tappable — no dead row',
      (tester) async {
    await _searchAndTap(
      tester,
      matches: [_msg('m1', 'a'), _msg('m2', 'b'), _msg('m3', 'c')],
      input: 'a',
      tippen: false,
    );
    final lines = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(lines, hasLength(3));
    expect(lines.every((z) => z.onTap != null), isTrue,
        reason: 'a preview with no way to it is the reported fault');
  });
}
