// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/security/security_providers.dart';
import '../decrypted_media_stream.dart';
import '../media_attachment.dart';
import '../media_repository.dart';
import '../media_saver.dart';
import '../video_source.dart';

/// Download (web + desktop) / share (mobile) action for a media message.
class MediaActionButton extends StatelessWidget {
  final MediaAttachment attachment;
  final Uint8List bytes;
  final Color? color;
  final double size;

  const MediaActionButton({
    super.key,
    required this.attachment,
    required this.bytes,
    this.color,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(mediaUsesShareSheet ? Icons.ios_share : Icons.download,
          size: size, color: color),
      tooltip: (mediaUsesShareSheet ? 'media.share' : 'media.download').tr(),
      onPressed: () async {
        try {
          await saveOrShareMedia(
            fileName: attachment.name,
            mimeType: attachment.mime,
            bytes: bytes,
          );
          logger.info(
              'Media ${mediaUsesShareSheet ? 'shared' : 'downloaded'}: ${attachment.name}',
              tag: 'MediaActionButton');
        } catch (e) {
          logger.error('Media save/share failed: $e',
              tag: 'MediaActionButton');
        }
      },
    );
  }
}

/// Download/share for a non-displayable file (pdf/apk/zip/…) whose bytes were
/// NOT decrypted for preview. Decrypts ON DEMAND, streaming to a temp file so a
/// large (chunked) file never sits whole in RAM — the same path videos use. A
/// spinner shows while it works.
class MediaFileActionButton extends ConsumerStatefulWidget {
  final MediaAttachment attachment;
  final Color? color;
  final double size;

  const MediaFileActionButton({
    super.key,
    required this.attachment,
    this.color,
    this.size = 20,
  });

  @override
  ConsumerState<MediaFileActionButton> createState() =>
      _MediaFileActionButtonState();
}

class _MediaFileActionButtonState extends ConsumerState<MediaFileActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final att = widget.attachment;
    try {
      final repo = ref.read(mediaRepositoryProvider);
      final svc = ref.read(messageEncryptionServiceProvider);
      // decryptedMediaChunks handles chunked AND single-object (+ gzip) and fires
      // the download-received signal (00056). Stream to a temp file, then hand
      // the path to the OS share sheet / save dialog.
      final src = await VideoSource.fromChunkStream(
          decryptedMediaChunks(att, repo, svc), att.name, att.mime);
      try {
        await saveOrShareMediaPath(
            sourcePath: src.uri, fileName: att.name, mimeType: att.mime);
      } finally {
        await src.dispose();
      }
      logger.info(
          'File ${mediaUsesShareSheet ? 'shared' : 'downloaded'}: ${att.name}',
          tag: 'MediaFileActionButton');
    } catch (e) {
      logger.error('File save/share failed: $e', tag: 'MediaFileActionButton');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return SizedBox(
        width: widget.size + 16,
        height: widget.size + 16,
        child: Center(
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(mediaUsesShareSheet ? Icons.ios_share : Icons.download,
          size: widget.size, color: widget.color),
      tooltip: (mediaUsesShareSheet ? 'media.share' : 'media.download').tr(),
      onPressed: _run,
    );
  }
}
