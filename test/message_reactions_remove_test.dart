// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Removing your own reaction (1.22). The design hinges on ONE decision: the
// remove path issues an explicit DELETE instead of reusing the toggle RPC.
// `toggle_message_reaction` decides by current state (IF EXISTS → DELETE ELSE
// INSERT), so a concurrent toggle from a second device turns an intended
// removal into a fresh insert. These tests nail that down.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/messages/message_reaction_model.dart';
import 'package:chattr/features/messages/message_reactions_controller.dart';
import 'package:chattr/features/messages/message_reactions_repository.dart';

const _me = 'me';
const _chatId = 'chat-1';
const _messageId = 'msg-1';

/// Records what the controller asked for and hands back a scripted summary.
class _FakeReactionsRepository implements MessageReactionsRepository {
  _FakeReactionsRepository(this.remaining);

  /// What a refetch returns — i.e. the server's view after the delete.
  List<ReactionSummary> remaining;

  final calls = <String>[];
  bool throwOnRemove = false;

  /// Completes the pending remove so a test can inspect the optimistic state
  /// before the server answers.
  Completer<void>? gate;

  @override
  Future<void> removeReaction(
    String messageId,
    String userId,
    String reaction,
  ) async {
    calls.add('removeReaction($messageId,$userId,$reaction)');
    if (gate != null) await gate!.future;
    if (throwOnRemove) throw Exception('offline');
  }

  @override
  Future<void> removeAllUserReactions(String messageId, String userId) async {
    calls.add('removeAllUserReactions($messageId,$userId)');
    if (gate != null) await gate!.future;
    if (throwOnRemove) throw Exception('offline');
  }

  @override
  Future<bool> toggleReaction(String messageId, String reaction) async {
    calls.add('toggleReaction($messageId,$reaction)');
    return false;
  }

  @override
  Future<List<ReactionSummary>> getReactionSummary(
    String messageId, {
    String? currentUserId,
  }) async {
    calls.add('getReactionSummary($messageId)');
    return remaining;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeAuthController extends StateNotifier<String?>
    implements AuthController {
  _FakeAuthController(super.state);

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

ProviderContainer _container(
  _FakeReactionsRepository repo, {
  String? userId = _me,
}) {
  final container = ProviderContainer(overrides: [
    messageReactionsRepositoryProvider.overrideWithValue(repo),
    authControllerProvider
        .overrideWith((ref) => _FakeAuthController(userId)),
    // The real one builds a Supabase client; the controller only needs it to
    // be absent so no realtime subscription is attempted.
    eventBusProvider.overrideWith((ref) => null),
  ]);
  addTearDown(container.dispose);
  // The provider is autoDispose: without a listener it is torn down at the
  // first await, and the controller then throws on `state`.
  container.listen(
    chatReactionsProvider(_chatId),
    (_, __) {},
    fireImmediately: true,
  );
  return container;
}

void main() {
  group('ChatReactionsController.removeOwnReaction', () {
    test('deletes explicitly instead of toggling', () async {
      final repo = _FakeReactionsRepository([]);
      final container = _container(repo);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);

      await notifier.removeOwnReaction(_messageId, '👍');

      expect(
        repo.calls,
        contains('removeReaction($_messageId,$_me,👍)'),
        reason: 'a toggle could re-add the reaction under a race',
      );
      expect(
        repo.calls.where((c) => c.startsWith('toggleReaction')),
        isEmpty,
      );
    });

    test('removes all own reactions in one call', () async {
      final repo = _FakeReactionsRepository([]);
      final container = _container(repo);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);

      await notifier.removeAllOwnReactions(_messageId);

      expect(repo.calls, contains('removeAllUserReactions($_messageId,$_me)'));
    });

    test('paints the removal before the server answers', () async {
      final repo = _FakeReactionsRepository([])..gate = Completer<void>();
      final container = _container(repo);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);

      // Seed the state as if the chat had been primed.
      await notifier.loadMessageReactions(_messageId);
      repo.remaining = [];
      notifier.state = {
        _messageId: [
          _summary('👍', [_me, 'other']),
        ],
      };

      final pending = notifier.removeOwnReaction(_messageId, '👍');
      await Future<void>.delayed(Duration.zero);

      final optimistic = notifier.getReactions(_messageId).single;
      expect(optimistic.count, 1);
      expect(optimistic.userReacted, isFalse);

      repo.gate!.complete();
      await pending;
    });

    test('a failed delete restores the reaction and rethrows', () async {
      final repo = _FakeReactionsRepository([
        _summary('👍', [_me, 'other']),
      ])
        ..throwOnRemove = true;
      final container = _container(repo);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);
      notifier.state = {
        _messageId: [
          _summary('👍', [_me, 'other']),
        ],
      };

      await expectLater(
        notifier.removeOwnReaction(_messageId, '👍'),
        throwsA(isA<Exception>()),
      );

      // The reconciling refetch runs in `finally`, so the optimistic removal
      // does not survive a failure.
      final restored = notifier.getReactions(_messageId).single;
      expect(restored.userReacted, isTrue);
      expect(restored.count, 2);
    });

    test('does nothing without a signed-in user', () async {
      final repo = _FakeReactionsRepository([]);
      final container = _container(repo, userId: null);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);

      await notifier.removeOwnReaction(_messageId, '👍');

      expect(repo.calls, isEmpty);
    });

    test('a second removal is a no-op, not an error', () async {
      // Idempotence is the whole point of using DELETE: a double tap, or a
      // row another device already deleted, must not blow up.
      final repo = _FakeReactionsRepository([]);
      final container = _container(repo);
      final notifier = container.read(chatReactionsProvider(_chatId).notifier);

      await notifier.removeOwnReaction(_messageId, '👍');
      await notifier.removeOwnReaction(_messageId, '👍');

      expect(notifier.getReactions(_messageId), isEmpty);
    });
  });
}
