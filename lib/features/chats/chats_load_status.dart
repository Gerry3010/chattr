// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/legacy.dart';

import '../auth/auth_controller.dart';

/// Where the chat list stands, next to the list itself.
///
/// The list alone cannot say it: an empty list was all of "Face ID was
/// cancelled", "the start failed" and "you really have no chats yet", and the
/// screen showed "Noch keine Chats" for all three. Gerry saw exactly that with
/// all his chats on the phone (2026-10-23).
enum ChatsLoadStatus {
  /// Nothing read yet.
  loading,

  /// Biometrics did not pass; the lock screen is up.
  locked,

  /// The local chats are in the list. From here an empty list means empty.
  ready,

  /// The local chats could not be read.
  failed,
}

/// Starts over with every account switch (login, logout), like the chat list.
final chatsLoadStatusProvider = StateProvider<ChatsLoadStatus>((ref) {
  ref.watch(authControllerProvider);
  return ChatsLoadStatus.loading;
});
