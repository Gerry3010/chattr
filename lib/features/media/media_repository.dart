// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'media_attachment.dart';

/// Thrown when the user aborts an in-flight media send via the progress box's
/// cancel button. Callers clean up any already-uploaded blobs and swallow it
/// (no error snackbar) — it isn't a failure.
class MediaSendCancelledException implements Exception {
  const MediaSendCancelledException();
  @override
  String toString() => 'MediaSendCancelledException';
}

/// Fire the per-recipient "downloaded" media-retention signal for [att] (00056),
/// swallowing any error. Fire-and-forget + idempotent; shared by the single-
/// object ([decryptedMediaProvider]) and chunked-stream ([decryptedMediaChunks])
/// decrypt paths. A miss just leaves the blob to the existing fallback windows.
void signalMediaDownloaded(MediaRepository repo, MediaAttachment att) {
  final ids = att.storageIds;
  if (ids == null) return;
  unawaited(
    repo.markDownloaded(ids.chatId, ids.messageId).catchError(
          (Object e) =>
              logger.info('markDownloaded skipped: $e', tag: 'MediaRepository'),
        ),
  );
}

/// Stores/loads the *ciphertext* of media files in the private `media` bucket.
/// The plaintext bytes never reach here — they're AES-encrypted client-side
/// first, so this only moves opaque blobs.
class MediaRepository {
  final SupabaseClient client;

  static const String bucket = 'media';

  /// Client-side upload ceiling. The server side is capped at 500 MiB
  /// (supabase/config.toml file_size_limit + FILE_SIZE_LIMIT in both
  /// docker-compose files + nginx client_max_body_size on the prod host —
  /// keep all of them in sync with this); 1 KiB headroom covers the AES-GCM
  /// envelope overhead (28 bytes) so we reject before encrypting and
  /// uploading a file the server would bounce anyway.
  static const int maxUploadBytes = 500 * 1024 * 1024 - 1024;

  /// Human-readable form of [maxUploadBytes] for error messages ("500 MB").
  static final String maxUploadLabel =
      '${((maxUploadBytes + 1024) / (1024 * 1024)).round()} MB';

  /// Above this, mobile devices get a memory warning before sending: encrypt
  /// currently holds the full file + ciphertext in RAM (no streaming), which
  /// can OOM low-end phones. Accepted risk per product decision — streaming
  /// encryption is a backlog item.
  static const int largeFileWarnBytes = 100 * 1024 * 1024;

  /// Hard ceiling for loading a picked file INTO memory. The bytes path holds
  /// the plaintext plus a ciphertext copy in RAM, so a file near this size peaks
  /// at ~2×. A larger file is refused up-front (clear message) instead of letting
  /// the byte allocation OOM-crash the app — the crash seen on a 113 MB pick.
  ///
  /// Now that any large PATH-backed file is streamed/chunked (see
  /// [chunkThresholdBytes]), this ceiling only bites the web/pathless case where
  /// there's no file path to stream from. Platform-aware: iOS has NO `largeHeap`
  /// equivalent and its jetsam killer terminates apps at a much lower footprint,
  /// so the ceiling is stricter there; Android's `largeHeap` buys more room.
  static int get maxInMemoryBytes {
    if (!kIsWeb && Platform.isIOS) return 90 * 1024 * 1024;
    return 200 * 1024 * 1024;
  }

  /// Human-readable form of [maxInMemoryBytes] ("90 MB" / "200 MB").
  static String get maxInMemoryLabel =>
      '${(maxInMemoryBytes / (1024 * 1024)).round()} MB';

  /// Files larger than this are sent CHUNKED (streamed from a path, never fully
  /// in RAM) instead of the single-object bytes path. Below it, the legacy
  /// single-object path is used (fast, old-client-compatible). Between this and
  /// [maxUploadBytes] (500 MB) is the chunked range that fixes the large-media
  /// OOM (videos and big documents/archives) without loading the whole file.
  static const int chunkThresholdBytes = 16 * 1024 * 1024;

  /// Plaintext bytes per chunk. Peak RAM per chunk ≈ 2× this (plaintext +
  /// ciphertext), so ~12 MiB — safe on iOS jetsam limits.
  static const int chunkSizeBytes = 6 * 1024 * 1024;

  MediaRepository(this.client);

  /// Signal that the calling recipient has downloaded + decrypted a media blob.
  ///
  /// A media-retention signal DECOUPLED from read receipts (00056): the server
  /// reaps the blob once EVERY recipient has confirmed a download, so it no
  /// longer lingers for the read+7d window (or up to 3 months when receipts are
  /// off). Fire-and-forget + idempotent — callers swallow errors; the worst case
  /// is the blob waiting out the existing fallback windows.
  Future<void> markDownloaded(String chatId, String messageId) =>
      client.rpc<void>(
        'mark_media_downloaded',
        params: {'p_message_id': messageId, 'p_chat_id': chatId},
      );

  /// The OPAQUE storage object path for one of a message's media objects (audit
  /// M9): no filename, just `<chatId>/<messageId>/media-<index>.enc`. The
  /// chatId/messageId segments are load-bearing (the media reaper keys on the
  /// messageId = 2nd segment, migration 00034 — filename-agnostic, so all of an
  /// album's `media-N.enc` are reaped/kept as one group); nothing derived from
  /// the user's filename appears. [index] distinguishes the objects of a
  /// multi-media album (#109); a single media is index 0.
  static String objectPath(String chatId, String messageId, {int index = 0}) =>
      '$chatId/$messageId/media-$index.enc';

  /// Upload an encrypted blob. Returns the stored object path.
  ///
  /// Path layout: `<chatId>/<messageId>/media-<index>.enc` — deliberately OPAQUE
  /// (audit M9). The real filename used to sit in the object path, leaking it
  /// to anyone who can list the bucket (server/admin); it now lives ONLY inside
  /// the per-recipient-encrypted [MediaAttachment] descriptor. [index] keeps an
  /// album's objects distinct under the same `<chatId>/<messageId>/` folder so
  /// the messageId-keyed reaper (migration 00034) still groups them. The
  /// chatId/messageId segments stay for exactly that reason. `fileName` is
  /// accepted for API compatibility but no longer path-embedded.
  Future<String> uploadEncrypted({
    required String chatId,
    required String messageId,
    required String fileName,
    required Uint8List blob,
    required MediaType kind,
    int index = 0,
  }) async {
    final path = objectPath(chatId, messageId, index: index);
    await client.storage.from(bucket).uploadBinary(
          path,
          blob,
          fileOptions: _fileOptions(kind),
        );
    return path;
  }

  /// Upload options for every media blob, carrying the coarse `x-media-kind`
  /// tag (`image`/`video`/`audio`/`other`).
  ///
  /// **What this deliberately does and does not leak.** The server already sees
  /// each blob's size and timestamp; the tag adds its rough category — nothing
  /// about the content, no filename, no mime subtype. That is the accepted
  /// price for the operator being able to answer "how much of my storage is
  /// video" without ever touching a blob (`metrics_media_by_kind`, 00058).
  /// Without it every object counts as `unknown` and the panel stays blank.
  ///
  /// The Supabase client sends this as a multipart `metadata` field, which
  /// storage-api persists in `storage.objects.user_metadata` — NOT the
  /// system-owned `metadata` column next to it. Migration 00066 reads the
  /// former; mixing the two up is why the split showed nothing before.
  static FileOptions _fileOptions(MediaType kind) => FileOptions(
        contentType: 'application/octet-stream',
        upsert: true,
        metadata: {'x-media-kind': kind.storageKind},
      );

  /// Object path of a video's cover-frame thumbnail:
  /// `<chatId>/<messageId>/media-<index>-thumb.enc`. Under the same
  /// `<chatId>/<messageId>/` folder as the video's objects, so the messageId-
  /// keyed reaper (migration 00034) groups + reaps it with the message — no new
  /// retention surface. [index] matches the album item it posters.
  static String thumbObjectPath(String chatId, String messageId,
          {int index = 0}) =>
      '$chatId/$messageId/media-$index-thumb.enc';

  /// Upload an encrypted video thumbnail. Returns its stored object path
  /// (tracked for transactional cleanup on send failure, like [uploadEncrypted]).
  Future<String> uploadEncryptedThumb({
    required String chatId,
    required String messageId,
    required Uint8List blob,
    int index = 0,
  }) async {
    final path = thumbObjectPath(chatId, messageId, index: index);
    await client.storage.from(bucket).uploadBinary(
          path,
          blob,
          // Tagged `video`, not `image`: a cover frame is storage that belongs
          // to a video message, and an operator asking how much space video
          // costs wants the poster counted with it. Tagging it `image` would
          // inflate the image count with objects no one ever sent.
          fileOptions: _fileOptions(MediaType.video),
        );
    return path;
  }

  /// The chunk-object PREFIX stored in a chunked [MediaAttachment.path]:
  /// `<chatId>/<messageId>/media-<attIndex>`. Chunk `i` lives at
  /// `"$prefix-chunk-$i.enc"` (see [MediaAttachment.chunkPath] /
  /// [chunkObjectPath]). Still under the `<chatId>/<messageId>/` folder, so the
  /// messageId-keyed reaper groups every chunk with the message.
  static String chunkPrefixPath(
    String chatId,
    String messageId, {
    required int attIndex,
  }) =>
      '$chatId/$messageId/media-$attIndex';

  /// Full storage path of one chunk — `"<prefix>-chunk-<chunkIndex>.enc"`.
  static String chunkObjectPath(
    String chatId,
    String messageId, {
    required int attIndex,
    required int chunkIndex,
  }) =>
      '${chunkPrefixPath(chatId, messageId, attIndex: attIndex)}-chunk-$chunkIndex.enc';

  /// Upload one encrypted chunk. Returns its stored object path (tracked for
  /// transactional cleanup on send failure, exactly like [uploadEncrypted]).
  Future<String> uploadEncryptedChunk({
    required String chatId,
    required String messageId,
    required int attIndex,
    required int chunkIndex,
    required Uint8List blob,
    required MediaType kind,
  }) async {
    final path = chunkObjectPath(chatId, messageId,
        attIndex: attIndex, chunkIndex: chunkIndex);
    await client.storage.from(bucket).uploadBinary(
          path,
          blob,
          // Every chunk carries its parent attachment's kind, so a 400 MB video
          // counts as video across all ~67 of its objects rather than dropping
          // the largest files in the bucket into `unknown`.
          fileOptions: _fileOptions(kind),
        );
    return path;
  }

  /// Download an encrypted blob by its object path.
  Future<Uint8List> downloadEncrypted(String path) async {
    return client.storage.from(bucket).download(path);
  }

  /// Best-effort delete (e.g. on send failure).
  Future<void> delete(String path) async {
    try {
      await client.storage.from(bucket).remove([path]);
    } catch (_) {}
  }
}

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  return MediaRepository(ref.read(supabaseClientProvider));
});
