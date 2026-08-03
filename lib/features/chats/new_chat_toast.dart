// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/legacy.dart';

/// A one-shot "you were added to a chat" toast request (#117).
///
/// [ChatsController] sets this when a `newChat` arrives for a chat the user did
/// NOT initiate (someone else scanned their QR / added them to a group). The
/// app-level [NewChatToastListener] shows a SnackBar with a "go to chat" action
/// and then clears it. Self-initiated chats never set it.
class NewChatToast {
  /// The chat to open on "go to chat".
  final String chatId;

  /// The ready-to-show message (already localized), e.g. "Alice added you".
  final String message;

  const NewChatToast({required this.chatId, required this.message});
}

/// Latest pending new-chat toast, or null. Set by ChatsController, consumed +
/// reset by NewChatToastListener.
final newChatToastProvider = StateProvider<NewChatToast?>((ref) => null);
