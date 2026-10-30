// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'typing_indicator_service.dart';

/// Provider for TypingIndicatorService
final typingIndicatorServiceProvider = Provider<TypingIndicatorService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final service = TypingIndicatorService(supabase);

  // The event bus re-joins after every drop and every return from the
  // background. The socket under all channels is new then, so the typing
  // channels are rebuilt along with it (CHAT-53). Listened, not watched: a new
  // bus after a login must not throw away the service and its open rooms.
  StreamSubscription<void>? resubscribed;
  ref.listen(
    eventBusProvider,
    (_, bus) {
      unawaited(resubscribed?.cancel());
      resubscribed =
          bus?.onResubscribed.listen((_) => unawaited(service.rebuildAll()));
    },
    fireImmediately: true,
  );

  ref.onDispose(() {
    unawaited(resubscribed?.cancel());
    service.dispose();
  });

  return service;
});

/// Provider for typing indicators stream for a specific chat.
///
/// autoDispose: leaving the chat closes its typing channel. It used to stay
/// open for the rest of the session for every chat ever opened, on a channel
/// whose name is the chat id (see CHAT-38).
final typingIndicatorsProvider =
    StreamProvider.autoDispose.family<List<String>, String>(
  (ref, chatId) {
    final service = ref.watch(typingIndicatorServiceProvider);
    ref.onDispose(() => unawaited(service.unsubscribe(chatId)));
    return service.subscribeToTypingIndicators(chatId);
  },
);
