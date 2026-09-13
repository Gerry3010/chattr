// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The "remove my reaction" entry in the long-press sheet (1.22). It only shows
// up when there IS something of yours to remove, it names what disappears, and
// it closes the sheet — the same contract as every other entry there.
//
// EasyLocalization is not initialised here, so `.tr()` returns the key itself.
// Matching happens on the ValueKey, not on visible text.

import 'package:chatview/chatview.dart' as chatview;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/message_reaction_model.dart';
import 'package:chattr/features/messages/message_reactions_controller.dart';
import 'package:chattr/features/messages/messages_controller.dart';
import 'package:chattr/screens/chat/components/message_actions_sheet.dart';

const _chatId = 'chat-1';
const _messageId = 'msg-1';

class _FakeChatReactionsController
    extends StateNotifier<Map<String, List<ReactionSummary>>>
    implements ChatReactionsController {
  _FakeChatReactionsController(super.state);

  final calls = <String>[];

  @override
  Future<void> removeOwnReaction(String messageId, String reaction) async {
    calls.add('one:$messageId:$reaction');
  }

  @override
  Future<void> removeAllOwnReactions(String messageId) async {
    calls.add('all:$messageId');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeMessagesController extends StateNotifier<List<MessageInterface>>
    implements MessagesController {
  _FakeMessagesController() : super(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ReactionSummary _mine(String emoji) => ReactionSummary(
      reaction: emoji,
      count: 1,
      userReacted: true,
      userIds: const ['me'],
    );

ReactionSummary _theirs(String emoji) => ReactionSummary(
      reaction: emoji,
      count: 1,
      userReacted: false,
      userIds: const ['other'],
    );

void main() {
  final message = chatview.Message(
    id: _messageId,
    message: 'hi',
    createdAt: DateTime.utc(2026, 8, 13),
    sentBy: 'other',
  );

  Future<_FakeChatReactionsController> openSheet(
    WidgetTester tester,
    List<ReactionSummary> summaries, {
    // Show all actions — only with the full list does the sheet get long enough
    // for the height limit to bite at all.
    bool allActions = false,
  }) async {
    final reactions = _FakeChatReactionsController({_messageId: summaries});

    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatReactionsProvider(_chatId).overrideWith((ref) => reactions),
        messagesControllerProvider(_chatId)
            .overrideWith((ref) => _FakeMessagesController()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // The chat screen keeps this provider alive (ChatViewController
              // listens to it); without a listener the autoDispose family is
              // torn down between opening the sheet and tapping the entry.
              ref.watch(chatReactionsProvider(_chatId));
              return Center(
                child: ElevatedButton(
                  onPressed: () => showMessageActionsSheet(
                    context: context,
                    ref: ref,
                    chatId: _chatId,
                    message: message,
                    copyText: 'hi',
                    onReply: allActions ? () {} : null,
                    onForward: allActions ? () {} : null,
                    onEdit: allActions ? () {} : null,
                    onDelete: allActions ? () {} : null,
                    onInfo: allActions ? () {} : null,
                    onReport: allActions ? () {} : null,
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

  final tile = find.byKey(const ValueKey('remove_own_reaction_tile'));

  testWidgets('no entry when nothing of yours is on the message',
      (tester) async {
    await openSheet(tester, [_theirs('\u{1F44D}')]);
    expect(tile, findsNothing);
  });

  testWidgets('one own reaction → singular label and that emoji',
      (tester) async {
    await openSheet(tester, [_mine('\u{1F44D}'), _theirs('\u{2764}')]);

    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('chat_view.reaction_remove_mine')),
      findsOneWidget,
    );
    // Only the reaction that is actually yours is offered for removal.
    expect(
      find.descendant(of: tile, matching: find.text('\u{1F44D}')),
      findsOneWidget,
    );
  });

  testWidgets('several own reactions → plural label listing all of them',
      (tester) async {
    await openSheet(tester, [_mine('\u{1F44D}'), _mine('\u{1F602}')]);

    expect(
      find.descendant(
          of: tile, matching: find.text('chat_view.reaction_remove_mine_all')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: tile, matching: find.text('\u{1F44D} \u{1F602}')),
      findsOneWidget,
    );
  });

  testWidgets('tapping removes the single reaction and closes the sheet',
      (tester) async {
    final reactions = await openSheet(tester, [_mine('\u{1F44D}')]);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(reactions.calls, ['one:$_messageId:\u{1F44D}']);
    expect(tile, findsNothing, reason: 'the sheet must close');
  });

  testWidgets('tapping with several removes them all in one go',
      (tester) async {
    final reactions =
        await openSheet(tester, [_mine('\u{1F44D}'), _mine('\u{1F602}')]);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(reactions.calls, ['all:$_messageId']);
  });

  // ── Reachability on small screens ────────────────────────────────────────
  // Reported by Gerry on 2026-08-19 with a screenshot: "delete" stuck to the
  // bottom edge of the screen and was barely hittable on the iPhone.
  //
  // The cause was not the missing SafeArea (that had long been there) but the
  // missing `isScrollControlled` — Flutter otherwise limits a bottom sheet to
  // 9/16 of the screen height and cuts off everything below, the safe inset
  // included. So this test checks BOTH: that the last entry is reachable at
  // all, and that it does not sit under the home indicator.
  testWidgets('the last entry stays reachable on short screens',
      (tester) async {
    // iPhone-artig: kurzer Bildschirm plus Home-Indikator unten.
    tester.view.physicalSize = const Size(390 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 34 * 3);
    tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
    addTearDown(tester.view.reset);

    await openSheet(
      tester,
      [_mine('\u{1F44D}')],
      allActions: true,
    );

    final loeschen = find.text('chat_view.delete');
    expect(loeschen, findsOneWidget, reason: 'the entry has to be in the tree');

    // Has to be scrollable into the visible area — before the fix there was no
    // vertical scroll surface at all, the entry was simply cut off. The
    // reaction row at the top scrolls horizontally, so the intended surface has
    // to be named explicitly.
    final senkrecht = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    );
    expect(senkrecht, findsOneWidget,
        reason: 'without a vertical scroll surface the entry is unreachable');
    await tester.scrollUntilVisible(loeschen, 80, scrollable: senkrecht);
    await tester.pumpAndSettle();

    final rect = tester.getRect(loeschen);
    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final safeBottom = tester.view.padding.bottom / tester.view.devicePixelRatio;

    expect(rect.bottom, lessThanOrEqualTo(screenHeight - safeBottom + 0.5),
        reason: 'sits under the home indicator: '
            'unten=${rect.bottom}, Grenze=${screenHeight - safeBottom}');

    // And it really has to fire, not merely be visible.
    await tester.tap(loeschen);
    await tester.pumpAndSettle();
    expect(loeschen, findsNothing, reason: 'the sheet has to close');
  });

  // Destructive things last. On the iPhone (build 67) "report" stood BELOW
  // "delete": the thumb runs to the bottom edge while scrolling, and that is
  // where the one action that takes something away lay. What is checked is the
  // vertical position, not the source order — only the former is what the user
  // sees, and only it stays correct should the entries later be built from a
  // list.
  testWidgets('delete stands below every other action', (tester) async {
    await openSheet(tester, const [], allActions: true);

    final loeschen = tester.getRect(find.text('chat_view.delete')).top;

    for (final andere in const [
      'chat_view.reply',
      'chat_view.copy',
      'chat_view.forward',
      // (Favorites need a real appMessage — not set here.)
      'chat_view.message_info',
      'chat_view.edit_message',
      'chat_view.report_message',
    ]) {
      final finder = find.text(andere);
      expect(finder, findsOneWidget, reason: '$andere fehlt im Sheet');
      expect(tester.getRect(finder).top, lessThan(loeschen),
          reason: '„$andere" liegt UNTER „Loeschen" — zerstoerendes gehoert '
              'ans Ende, sonst greift der Daumen am Rand daneben');
    }
  });
}
