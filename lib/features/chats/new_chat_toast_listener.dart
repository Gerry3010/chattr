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
          // 10 Sekunden, mehr als beim Weiterleiten: dieser Hinweis kommt
          // UNAUFGEFORDERT, womöglich mitten in etwas anderem. Bis der Blick
          // überhaupt dort ist, sind zwei Sekunden weg.
          duration: const Duration(seconds: 10),
          // persist: false ist PFLICHT, sobald eine Aktion dranhängt.
          // Flutter setzt `persist = persist ?? action != null` — ein
          // SnackBar mit Aktionsknopf bleibt also standardmäßig FÜR IMMER
          // stehen, bis jemand die Aktion antippt. Eine gesetzte `duration`
          // wird dabei stillschweigend ignoriert.
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
