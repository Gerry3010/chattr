// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The app's own "who reacted" sheet (1.22, fork p24). Two things must hold:
// only YOUR row offers a way out (a swipe is invisible, so a wrong row would
// be a trap), and the sheet reflects the removal rather than leaving a row on
// screen the way the package's immutable snapshot did.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/messages/message_reaction_model.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/messages/message_reactions_controller.dart';
import 'package:chattr/screens/chat/components/reaction_details_sheet.dart';

const _chatId = 'chat-1';
const _messageId = 'msg-1';
const _me = 'me';
const _other = 'other';

class _FakeChatReactionsController
    extends StateNotifier<Map<String, List<ReactionSummary>>>
    implements ChatReactionsController {
  _FakeChatReactionsController(super.state);

  final removed = <String>[];

  @override
  Future<void> removeOwnReaction(String messageId, String reaction) async {
    removed.add(reaction);
    // What the real controller does: paint it gone straight away.
    state = {
      messageId: withoutUserReaction(state[messageId] ?? [], _me, reaction),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeAuthController extends StateNotifier<String?>
    implements AuthController {
  _FakeAuthController() : super(_me);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Names and avatars come through here; the real one builds a Supabase client.
class _FakeProfilesController extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfilesController()
      : super({
          _me: Profile(
            id: _me,
            username: 'Ich',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          _other: Profile(
            id: _other,
            username: 'Andere',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        });

  @override
  String? avatarUrl(String? avatarPath) => null;

  @override
  Future<void> loadProfile(String userId, {bool forceRefresh = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ReactionSummary _summary(String emoji, List<String> ids) => ReactionSummary(
      reaction: emoji,
      count: ids.length,
      userReacted: ids.contains(_me),
      userIds: ids,
    );

void main() {
  Future<_FakeChatReactionsController> open(
    WidgetTester tester,
    List<ReactionSummary> summaries,
  ) async {
    final reactions = _FakeChatReactionsController({_messageId: summaries});

    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatReactionsProvider(_chatId).overrideWith((ref) => reactions),
        authControllerProvider.overrideWith((ref) => _FakeAuthController()),
        profilesControllerProvider
            .overrideWith((ref) => _FakeProfilesController()),
        // Avatars come from a private bucket now: the real provider builds a
        // Supabase client to sign a URL. No picture in a widget test — the
        // initials circle is what renders.
        avatarSignedUrlProvider.overrideWith((ref, args) => null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              ref.watch(chatReactionsProvider(_chatId));
              return Center(
                child: ElevatedButton(
                  onPressed: () => showReactionDetailsSheet(
                    context: context,
                    chatId: _chatId,
                    messageId: _messageId,
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return reactions;
  }

  Finder rowRemove(String userId, String emoji) =>
      find.byKey(ValueKey('reaction_remove_$userId|$emoji'));

  testWidgets('only your own row can be removed', (tester) async {
    await open(tester, [
      _summary('\u{1F44D}', [_me, _other]),
    ]);

    expect(rowRemove(_me, '\u{1F44D}'), findsOneWidget);
    expect(rowRemove(_other, '\u{1F44D}'), findsNothing);
    // A stranger's row must not be swipeable either.
    expect(find.byType(Dismissible), findsOneWidget);
  });

  testWidgets('the remove button takes your reaction back', (tester) async {
    final reactions = await open(tester, [
      _summary('\u{1F44D}', [_me, _other]),
    ]);

    await tester.tap(rowRemove(_me, '\u{1F44D}'));
    await tester.pumpAndSettle();

    expect(reactions.removed, ['\u{1F44D}']);
    // The row is gone, the other person's stays.
    expect(rowRemove(_me, '\u{1F44D}'), findsNothing);
    expect(find.byKey(const ValueKey('reaction_row_$_other|\u{1F44D}')),
        findsOneWidget);
  });

  testWidgets('swiping your row left removes it too', (tester) async {
    final reactions = await open(tester, [
      _summary('\u{1F44D}', [_me, _other]),
    ]);

    await tester.drag(
      find.byKey(const ValueKey('reaction_row_$_me|\u{1F44D}')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(reactions.removed, ['\u{1F44D}']);
  });

  testWidgets('removing the last reaction closes the sheet', (tester) async {
    await open(tester, [
      _summary('\u{1F44D}', [_me]),
    ]);

    await tester.tap(rowRemove(_me, '\u{1F44D}'));
    await tester.pumpAndSettle();

    expect(find.text('chat_view.reactions_title'), findsNothing);
  });

  testWidgets('one row per emoji when you reacted more than once',
      (tester) async {
    await open(tester, [
      _summary('\u{1F44D}', [_me]),
      _summary('\u{1F602}', [_me, _other]),
    ]);

    expect(rowRemove(_me, '\u{1F44D}'), findsOneWidget);
    expect(rowRemove(_me, '\u{1F602}'), findsOneWidget);
    expect(rowRemove(_other, '\u{1F602}'), findsNothing);
  });
}
