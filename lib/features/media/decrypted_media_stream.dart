// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import '../../core/security/message_encryption_service.dart';
import 'media_attachment.dart';
import 'media_compression.dart';
import 'media_repository.dart';

/// Wie viele Bloecke gleichzeitig unterwegs sein duerfen. Drei deckt die
/// Wartezeit einer Anforderung ab, ohne den Speicher zu fluten (3 x 6 MiB).
const int mediaChunkLookahead = 3;

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
///
/// **Prefetch (1.27).** The blocks used to be fetched strictly one after another:
/// request, wait, decrypt, next. At 6 MiB per block that is around 67 full network
/// round trips in a row for a 400 MB video, and during every wait the device does
/// nothing. Now up to [mediaChunkLookahead] requests run at once, while the
/// finished ones are **still decrypted and yielded in order** — the file is written
/// sequentially, nothing about the order may change.
///
/// The window is deliberately narrow: every block in flight lies encrypted in
/// memory, and `MediaRepository.maxInMemoryBytes` is 90 MiB on the iPhone. Whoever
/// gets generous here trades stutter for crashes.
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
    final pending = <int, Future<Uint8List>>{};
    for (var i = 0; i < count; i++) {
      // Fill the window from the current block onwards. `putIfAbsent` holds on
      // to requests already running instead of issuing them twice.
      final until =
          (i + mediaChunkLookahead) < count ? i + mediaChunkLookahead : count;
      for (var j = i; j < until; j++) {
        pending.putIfAbsent(j, () {
          final f = repo.downloadEncrypted(att.chunkPath(j));
          // IMMEDIATELY, not only during cleanup: if a prefetched block fails
          // while we are still waiting on an earlier one, its error has no
          // taker at that moment — and Dart reports it as unhandled, with a
          // stack trace in the log, although the real error arrives properly
          // straight afterwards. `ignore` only attaches a silent listener; the
          // later `await` gets value and error unchanged.
          f.ignore();
          return f;
        });
      }
      final blob = await pending.remove(i)!;
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
