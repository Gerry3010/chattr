// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import '../../core/security/message_encryption_service.dart';
import 'media_attachment.dart';
import 'media_compression.dart';
import 'media_repository.dart';

/// Yields the DECRYPTED plaintext of [att] as a stream of byte chunks, never
/// holding the whole file in memory (chunked media receive). Platform-agnostic:
/// the consumer decides where the chunks go (a temp file on native, a Blob on
/// web).
///
/// - Chunked media: each object is downloaded, its per-chunk AAD rebuilt from
///   the prefix path ([MediaAttachment.chunkCoordinates]) + index/count and
///   verified by the GCM tag, then the plaintext is yielded one chunk at a time.
///   A reordered/dropped/spliced/tampered chunk throws.
/// - Legacy single-object media: the one blob is downloaded, decrypted,
///   gunzipped if flagged, and yielded once.
///
/// [onProgress] reports 0..1 as chunks complete (for a load indicator).
Stream<Uint8List> decryptedMediaChunks(
  MediaAttachment att,
  MediaRepository repo,
  MessageEncryptionService svc, {
  void Function(double progress)? onProgress,
}) async* {
  final key = base64Decode(att.keyB64);
  if (att.isChunked) {
    final coords = att.chunkCoordinates;
    final count = att.chunkCount!;
    if (coords == null) {
      throw StateError('chunked media path is not a chunk prefix: ${att.path}');
    }
    for (var i = 0; i < count; i++) {
      final blob = await repo.downloadEncrypted(att.chunkPath(i));
      final aad = MessageEncryptionService.mediaChunkAad(
          coords.messageId, coords.attIndex, i, count);
      yield await svc.decryptChunk(blob, key, aad: aad);
      onProgress?.call((i + 1) / count);
    }
    // Whole blob streamed successfully → signal the download (00056).
    signalMediaDownloaded(repo, att);
  } else {
    final blob = await repo.downloadEncrypted(att.path);
    var plain = await svc.decryptBytes(blob, key);
    if (att.compression == MediaCompression.gzip) {
      plain = await MediaCompression.decompress(plain,
          maxBytes: MediaRepository.maxUploadBytes);
    }
    onProgress?.call(1);
    yield plain;
    signalMediaDownloaded(repo, att);
  }
}
