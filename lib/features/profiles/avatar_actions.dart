// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/avatar_image_pick.dart';
import 'profiles_controller.dart';

/// Pick an image and upload it as [userId]'s avatar. Shared by the chat list
/// and the settings screen.
///
/// The format is decided by [pickAvatarImage] from the actual bytes, not from
/// the file name — the previous "extension → content type, else assume JPEG"
/// rule is what put HEIC files into storage under a JPEG label.
Future<void> pickAndUploadAvatar(
  BuildContext context,
  WidgetRef ref,
  String userId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await pickAvatarImage();
    if (picked == null) return;

    await ref.read(profilesControllerProvider.notifier).uploadAvatar(
          userId: userId,
          bytes: picked.bytes,
          fileExtension: picked.extension,
          contentType: picked.mime,
        );
    messenger.showSnackBar(
      SnackBar(content: Text('profile.avatar_updated'.tr())),
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
      SnackBar(content: Text('profile.avatar_error'.tr(args: ['$e']))),
    );
  }
}
