// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/navigation/navigation_provider.dart';
import 'chats_controller.dart';
import 'new_chat_toast.dart';

/// App-level listener that surfaces a "you were added to a chat" SnackBar (#117)
/// with a "go to chat" action when SOMEONE ELSE adds the user to a chat.
///
/// [ChatsController] decides when to fire (self-initiated chats are suppressed)
/// and sets [newChatToastProvider]; this widget shows it and resets it. Mirrors
/// [WebUpdateListener] — data logic lives in the controller, the widget only
/// renders, per the architecture's golden rule.
class NewChatToastListener extends ConsumerWidget {
  final Widget child;

  const NewChatToastListener({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<NewChatToast?>(newChatToastProvider, (previous, toast) {
      if (toast == null) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(toast.message),
          // 10 seconds, more than for forwarding: this notice arrives UNBIDDEN,
          // possibly in the middle of something else. By the time the eye is
          // even there, two seconds are gone.
          duration: const Duration(seconds: 10),
          // persist: false is MANDATORY as soon as an action hangs on it.
          // Flutter sets `persist = persist ?? action != null` — so a SnackBar
          // with an action button stays up FOREVER by default until somebody
          // taps the action. A `duration` that has been set is silently ignored
          // in that case.
          persist: false,
          action: SnackBarAction(
            label: 'chats.open_chat'.tr(),
            onPressed: () {
              final match = ref
                  .read(chatsControllerProvider)
                  .where((c) => c.id == toast.chatId);
              if (match.isNotEmpty) {
                ref.read(navigationServiceProvider).navigateToChat(match.first);
              }
            },
          ),
        ),
      );
      // One-shot: clear so it can't re-fire on a rebuild.
      Future.microtask(
        () => ref.read(newChatToastProvider.notifier).state = null,
      );
    });
    return child;
  }
}
