// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_types.dart';
import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chats_controller.dart';
import '../chats/chats_repository.dart';
import 'chat_request_model.dart';
import 'chat_requests_repository.dart';

final chatRequestsRepositoryProvider = Provider<ChatRequestsRepository>((ref) {
  return ChatRequestsRepository(ref.read(supabaseClientProvider));
});

/// Open requests to me.
///
/// Hangs on the event bus rather than on a connection of its own — the golden
/// rule from `docs/ARCHITECTURE.md`: one channel per user, listeners never in
/// the widget. The server sends `chatRequest` without an id; the list then
/// refetches itself.
final incomingChatRequestsProvider =
    AsyncNotifierProvider<IncomingChatRequests, List<IncomingChatRequest>>(
  IncomingChatRequests.new,
);

class IncomingChatRequests extends AsyncNotifier<List<IncomingChatRequest>> {
  @override
  Future<List<IncomingChatRequest>> build() async {
    if (ref.read(authControllerProvider) == null) return const [];

    final bus = ref.watch(eventBusProvider);
    if (bus != null) {
      final sub = bus
          .eventStreamOf<ChatRequestEvent>()
          .listen((_) => unawaited(refresh()));
      ref.onDispose(sub.cancel);
    }

    return ref.read(chatRequestsRepositoryProvider).incoming();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(chatRequestsRepositoryProvider).incoming(),
    );
  }

  /// Accepting creates the chat and pulls it into the local list at once —
  /// otherwise the freshly accepted conversation would only appear after the
  /// next event, and the jump to it would go nowhere.
  Future<String> accept(String requesterId) async {
    final chatId =
        await ref.read(chatRequestsRepositoryProvider).accept(requesterId);
    await ref.read(chatsControllerProvider.notifier).addChat(chatId);
    await refresh();
    ref.invalidate(outgoingChatRequestsProvider);
    return chatId;
  }

  Future<void> decline(String requesterId, {bool block = false}) async {
    await ref
        .read(chatRequestsRepositoryProvider)
        .decline(requesterId, block: block);
    await refresh();
  }
}

/// What I have sent. No bus event: a rejection deliberately sends nothing
/// (00082), and an acceptance arrives as `newChat` anyway.
final outgoingChatRequestsProvider =
    FutureProvider<List<OutgoingChatRequest>>((ref) async {
  if (ref.watch(authControllerProvider) == null) return const [];
  return ref.read(chatRequestsRepositoryProvider).outgoing();
});

/// Counter for the badge in the chat list.
final incomingChatRequestCountProvider = Provider<int>((ref) {
  return ref.watch(incomingChatRequestsProvider).asData?.value.length ?? 0;
});

/// The state regarding ONE person: existing chat, open request in one direction
/// or the other, or nothing.
///
/// `findDirectChat` asks the server whether we already share a 1:1. That is the
/// only reliable route today — an accepted request may lie in the opposite
/// direction and then does not appear in my list at all.
///
/// **Why the chat list is watched here.** Measured on staging on 2026-08-25:
/// the sheet still showed "request sent — waiting for an answer", although the
/// other party had accepted six seconds earlier and the chat already existed.
/// The state was computed once on opening, and after that nothing nudged it —
/// in precisely the moment the answer changes, the display stood still.
///
/// `accept_chat_request` sends the requester a `newChat`, the ChatsController
/// enters the chat into its list. Watching that list is therefore enough for
/// the row to flip to "open chat" by itself — and that WITHOUT a second event
/// source that would have to be maintained separately.
final chatRequestStatusProvider =
    FutureProvider.autoDispose.family<ChatRequestStatus, String>(
  (ref, peerId) async {
    final myId = ref.watch(authControllerProvider);
    if (myId == null) {
      return (state: ChatRequestState.none, chatId: null);
    }
    if (peerId == myId) {
      return (state: ChatRequestState.self, chatId: null);
    }

    // Do not use the result but the dependency: if the list grows by the
    // freshly accepted chat, this provider recomputes. Deliberately only the
    // COUNT — watching the whole list would mean asking the server about an
    // existing 1:1 again on every incoming message (it moves `lastMessageAt`).
    ref.watch(chatsControllerProvider.select((chats) => chats.length));

    String? existing;
    try {
      existing = await ref
          .read(chatsRepositoryProvider)
          .findDirectChat(peerId, myId);
    } catch (e) {
      // No reason to hide the row entirely: without an answer it simply offers
      // "request", and the server rejects a superfluous one.
      logger.warning(
        'Bestehenden 1:1 mit $peerId nicht ermittelt: $e',
        tag: 'ChatRequests',
      );
    }

    final incoming =
        await ref.watch(incomingChatRequestsProvider.future).catchError(
              (_) => const <IncomingChatRequest>[],
            );
    final outgoing =
        await ref.watch(outgoingChatRequestsProvider.future).catchError(
              (_) => const <OutgoingChatRequest>[],
            );

    return chatRequestStatusFor(
      peerId: peerId,
      myId: myId,
      existingChatId: existing,
      incoming: incoming,
      outgoing: outgoing,
    );
  },
);
