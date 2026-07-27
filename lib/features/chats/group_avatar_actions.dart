// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_model.dart';
import 'chats_controller.dart';

const _contentTypes = {
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
};

/// Pick an image from the gallery/files and upload it as [chat]'s group avatar
/// (admin only, 00055). Mirrors [pickAndUploadAvatar] for user profiles.
Future<void> pickAndUploadGroupAvatar(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.firstOrNull;
    if (file == null || file.bytes == null) return;
    await _uploadGroupAvatar(
      ref,
      messenger,
      chat: chat,
      bytes: file.bytes!,
      ext: (file.extension ?? 'jpg').toLowerCase(),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('chat_detail.avatar_error'.tr(args: ['$e']))),
    );
  }
}

/// Capture a photo with the camera and upload it as [chat]'s group avatar
/// (admin only, 1.8.1). Uses image_picker (same as the media camera capture).
Future<void> captureAndUploadGroupAvatar(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera);
    if (shot == null) return;
    final bytes = await shot.readAsBytes();
    final ext = shot.name.contains('.')
        ? shot.name.split('.').last.toLowerCase()
        : 'jpg';
    await _uploadGroupAvatar(ref, messenger, chat: chat, bytes: bytes, ext: ext);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('chat_detail.avatar_error'.tr(args: ['$e']))),
    );
  }
}

Future<void> _uploadGroupAvatar(
  WidgetRef ref,
  ScaffoldMessengerState messenger, {
  required Chat chat,
  required Uint8List bytes,
  required String ext,
}) async {
  final path = await ref.read(chatsControllerProvider.notifier).uploadGroupAvatar(
        chat: chat,
        bytes: bytes,
        fileExtension: ext,
        contentType: _contentTypes[ext] ?? 'image/jpeg',
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
}
