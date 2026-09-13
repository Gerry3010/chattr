// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/avatar_image_pick.dart';
import 'chat_model.dart';
import 'chats_controller.dart';

/// Pick an image from the gallery/files and upload it as [chat]'s group avatar
/// (admin only, 00055). Mirrors [pickAndUploadAvatar] for user profiles —
/// including the format rules, which are decided from the bytes.
Future<void> pickAndUploadGroupAvatar(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  await _pickThenUpload(context, ref, chat, pickAvatarImage);
}

/// Capture a photo with the camera and upload it as [chat]'s group avatar
/// (admin only, 1.8.1).
Future<void> captureAndUploadGroupAvatar(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  await _pickThenUpload(context, ref, chat, captureAvatarImage);
}

Future<void> _pickThenUpload(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  Future<PickedAvatar?> Function() source,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await source();
    if (picked == null) return;

    final path =
        await ref.read(chatsControllerProvider.notifier).uploadGroupAvatar(
              chat: chat,
              bytes: picked.bytes,
              fileExtension: picked.extension,
              contentType: picked.mime,
            );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          path != null
              ? 'chat_detail.avatar_updated'.tr()
              : 'chat_detail.avatar_error'.tr(args: ['—']),
        ),
      ),
    );
  } on UnsupportedAvatarFormat catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          e.isHeif
              ? 'profile.avatar_format_heic'.tr()
              : 'profile.avatar_format_unsupported'.tr(),
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('chat_detail.avatar_error'.tr(args: ['$e']))),
    );
  }
}
