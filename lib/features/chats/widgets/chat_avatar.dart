// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../identity/identity_color.dart';
import '../../profiles/widgets/user_avatar.dart';
import '../chat_members_controller.dart';
import '../chats_controller.dart';
import 'group_avatar.dart';

/// Reactive avatar for a *chat* (as opposed to a single user): renders the
/// uploaded group picture for a group, or the 1:1 partner's profile photo for a
/// direct chat, each with the usual initials/icon fallback. One component for
/// every chat-row avatar (chat list, forward/share sheet, global search) so they
/// all stay in sync and none fall back to a bare initials circle.
class ChatAvatar extends ConsumerWidget {
  final String chatId;
  final double radius;

  /// Coloured-initials fallback shown while the 1:1 partner isn't resolvable
  /// yet (keeps the row's look stable). Falls back to a person icon if null.
  final Color? fallbackColor;
  final String? fallbackInitial;

  const ChatAvatar({
    super.key,
    required this.chatId,
    this.radius = 20,
    this.fallbackColor,
    this.fallbackInitial,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats =
        ref.watch(chatsControllerProvider).where((c) => c.id == chatId);
    final chat = chats.isEmpty ? null : chats.first;

    if (chat?.isGroup ?? false) {
      return GroupAvatar(chatId: chatId, radius: radius);
    }

    final currentUserId = ref.watch(authControllerProvider);
    final members =
        ref.watch(chatMembersProvider(chatId)).whenOrNull(data: (m) => m) ??
            const <String>[];
    final otherId = members.firstWhere(
      (id) => id != currentUserId,
      orElse: () => '',
    );
    if (otherId.isEmpty) {
      // Resolve the background explicitly (was: pass null and inherit the M3
      // CircleAvatar default) — the letter's colour is derived from it, so an
      // unknown background meant an uncontrasted, theme-default letter here
      // while every other surface contrast-picked one.
      final bg = fallbackColor ?? Theme.of(context).colorScheme.primaryContainer;
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg,
        child: fallbackInitial != null && fallbackInitial!.trim().isNotEmpty
            ? Text(
                initialsFor(fallbackInitial!),
                style: IdentityColor.initialsTextStyle(radius, bg),
              )
            : Icon(
                Icons.person,
                size: radius,
                color: IdentityColor.foregroundOn(bg),
              ),
      );
    }
    return UserAvatar(userId: otherId, radius: radius);
  }
}
