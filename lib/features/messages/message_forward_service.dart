// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/security_providers.dart';
import '../media/decrypted_media_stream.dart';
import '../media/media_attachment.dart';
import '../media/media_compression.dart';
import '../media/media_repository.dart';
import '../media/video_source.dart';
import 'messages_controller.dart';

/// Forwards messages into another chat by re-sending them through the target
/// chat's normal send pipeline (fresh per-recipient encryption, TTL, local
/// persistence all included).
///
/// Holds a [WidgetRef] (same pattern as `ChatViewReactionsAdapter`) because
/// `messagesControllerProvider` is autoDispose — the target chat is usually
/// not open, so the provider must be kept alive for the duration of the send
/// via [WidgetRef.listenManual].
class MessageForwardService {
  final WidgetRef ref;

  MessageForwardService(this.ref);

  /// Forward a plain text message to [targetChatId].
  Future<void> forwardText(String targetChatId, String text) {
    return _withTargetController(
      targetChatId,
      // A failure leaves a failed bubble in the target chat (CHAT-66) and
      // still reaches the caller, which reports how many went through.
      (controller) => controller.sendMessage(text, rethrowFailure: true),
    );
  }

  /// Forward a media album: download + decrypt EVERY item's source blob, then
  /// re-send the whole album through the target chat's media pipeline (fresh
  /// media key + new storage objects under the target chat's folder — storage
  /// RLS scopes read access by chat folder, so blobs cannot be relinked). The
  /// shared caption travels along.
  Future<void> forwardAlbum(String targetChatId, MediaAlbum album) async {
    final repo = ref.read(mediaRepositoryProvider);
    final svc = ref.read(messageEncryptionServiceProvider);
    final files = <OutgoingMedia>[];
    // Chunked items are streamed to a temp file and re-sent from that path (the
    // target re-chunks) — never the whole video in RAM. Sources are disposed
    // after the send completes.
    final sources = <VideoSource>[];
    for (final att in album.items) {
      if (att.isChunked) {
        final src = await VideoSource.fromChunkStream(
            decryptedMediaChunks(att, repo, svc), att.name, att.mime);
        sources.add(src);
        files.add(OutgoingMedia.file(src.uri,
            size: att.size, fileName: att.name, mime: att.mime));
        continue;
      }
      final blob = await repo.downloadEncrypted(att.path);
      var bytes = await svc.decryptBytes(blob, base64Decode(att.keyB64));
      if (att.compression == MediaCompression.gzip) {
        // sendMediaAlbum below recompresses for the target chat.
        bytes = await MediaCompression.decompress(
          bytes,
          maxBytes: MediaRepository.maxUploadBytes,
        );
      }
      files.add(OutgoingMedia.bytes(bytes, fileName: att.name, mime: att.mime));
    }

    try {
      await _withTargetController(
        targetChatId,
        (controller) =>
            controller.sendMediaAlbum(files: files, caption: album.caption),
      );
    } finally {
      for (final s in sources) {
        await s.dispose();
      }
    }
  }

  Future<void> _withTargetController(
    String targetChatId,
    Future<void> Function(MessagesController controller) action,
  ) async {
    // Keep the autoDispose controller alive while the send is in flight.
    final subscription = ref.listenManual(
      messagesControllerProvider(targetChatId),
      (previous, next) {},
    );
    try {
      await action(
        ref.read(messagesControllerProvider(targetChatId).notifier),
      );
    } finally {
      subscription.close();
    }
  }
}
