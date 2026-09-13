// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../identity/identity_color.dart';
import '../chat_model.dart';
import '../chats_controller.dart';
import '../../profiles/avatar_url_cache.dart';

/// Circular avatar for a group chat (00055): shows the uploaded group picture
/// when available, otherwise falls back to a group icon on the chat's derived
/// color. Chat-id-based, mirroring [UserAvatar] for 1:1 profiles.
class GroupAvatar extends ConsumerWidget {
  final String chatId;
  final double radius;
  final VoidCallback? onTap;

  const GroupAvatar({
    super.key,
    required this.chatId,
    this.radius = 20,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats =
        ref.watch(chatsControllerProvider).where((c) => c.id == chatId);
    final Chat? chat = chats.isEmpty ? null : chats.first;
    // Signed and short-lived (00075). The signature changes on every refresh,
    // which also replaces the old `?u=<updatedAt>` cache-buster.
    final url = ref.watch(avatarSignedUrlProvider(
      (bucket: kGroupAvatarBucket, path: chat?.avatarPath ?? ''),
    ));

    final Widget avatar = url != null
        ? CircleAvatar(
            radius: radius,
            backgroundColor: chat?.color,
            backgroundImage: NetworkImage(url),
            onBackgroundImageError: (_, _) {},
          )
        : CircleAvatar(
            radius: radius,
            backgroundColor: chat?.color,
            child: Icon(
              Icons.group,
              size: radius,
              // Was hardcoded white — unreadable on the light half of the chat
              // palette (yellow/green hues drop to ~1.9:1).
              color: IdentityColor.foregroundOn(chat?.color ?? Colors.grey),
            ),
          );

    if (onTap == null) return avatar;
    return GestureDetector(onTap: onTap, child: avatar);
  }
}

/// Opens a fullscreen, pinch-zoom viewer of a GROUP's avatar (1.8.1 fix: the
/// group avatar tap previously opened the user viewer, showing the wrong image).
/// Falls back to a large group icon when the group has no uploaded picture.
void showGroupAvatarViewer(BuildContext context, String chatId) {
  Navigator.of(context).push(
    appPageRoute<void>(
      builder: (_) => _GroupAvatarViewerScreen(chatId: chatId),
    ),
  );
}

class _GroupAvatarViewerScreen extends ConsumerWidget {
  final String chatId;

  const _GroupAvatarViewerScreen({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats =
        ref.watch(chatsControllerProvider).where((c) => c.id == chatId);
    final Chat? chat = chats.isEmpty ? null : chats.first;
    // Signed and short-lived (00075). The signature changes on every refresh,
    // which also replaces the old `?u=<updatedAt>` cache-buster.
    final url = ref.watch(avatarSignedUrlProvider(
      (bucket: kGroupAvatarBucket, path: chat?.avatarPath ?? ''),
    ));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(chat?.name ?? ''),
      ),
      body: Center(
        child: url != null
            ? InteractiveViewer(
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: 0.8,
                maxScale: 5,
                child: Image.network(url),
              )
            : CircleAvatar(
                radius: 96,
                backgroundColor: chat?.color,
                child: Icon(
                  Icons.group,
                  size: 96,
                  color: IdentityColor.foregroundOn(chat?.color ?? Colors.grey),
                ),
              ),
      ),
    );
  }
}
