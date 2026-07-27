// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'profiles_controller.dart';

/// Pick an image and upload it as [userId]'s avatar. Shared by the chat list
/// and the settings screen.
Future<void> pickAndUploadAvatar(
  BuildContext context,
  WidgetRef ref,
  String userId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.firstOrNull;
    if (file == null || file.bytes == null) return;

    final ext = (file.extension ?? 'jpg').toLowerCase();
    const contentTypes = {
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
    };
    await ref.read(profilesControllerProvider.notifier).uploadAvatar(
          userId: userId,
          bytes: file.bytes!,
          fileExtension: ext,
          contentType: contentTypes[ext] ?? 'image/jpeg',
        );
    messenger.showSnackBar(
      SnackBar(content: Text('profile.avatar_updated'.tr())),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('profile.avatar_error'.tr(args: ['$e']))),
    );
  }
}
