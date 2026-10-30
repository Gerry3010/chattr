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
import 'media_blob_store.dart';

/// Thrown when the user aborts an in-flight media send via the progress box's
/// cancel button. Callers clean up any already-uploaded blobs and swallow it
/// (no error snackbar) — it isn't a failure.
class MediaSendCancelledException implements Exception {
  const MediaSendCancelledException();
  @override
  String toString() => 'MediaSendCancelledException';
}

/// The blob is gone from the server (reaped, 00056) and there is no local
/// copy either. Final: no retry can bring it back.
class MediaGoneException implements Exception {
  const MediaGoneException(this.path);
  final String path;
  @override
  String toString() => 'MediaGoneException($path)';
}

/// Storage answers a missing object with 404, or 400 + "Object not found"
/// (storage-api versions differ).
bool isObjectGone(StorageException e) =>
    e.statusCode == '404' ||
    (e.statusCode == '400' &&
        '${e.error} ${e.message}'.toLowerCase().contains('not found'));

/// Fire the per-recipient "downloaded" media-retention signal for [att]
/// (00056), swallowing any error. Fire-and-forget + idempotent; shared by the
/// single-object ([decryptedMediaProvider]) and chunked-stream
/// ([decryptedMediaChunks]) decrypt paths.
///
/// The server deletes the blob once everyone has signalled, so the signal
/// must mean "this device KEEPS it", not "has seen it once": every part of
/// the attachment must be in the local store first. A video's poster is
/// fetched here if it isn't yet, or it would go with the blob. Without a
/// complete local copy nothing is sent and the server keeps its copy until
/// the fallback windows.
void signalMediaDownloaded(MediaRepository repo, MediaAttachment att) {
  final ids = att.storageIds;
  if (ids == null) return;
  unawaited(() async {
    try {
      final thumb = att.thumbPath;
      if (thumb != null && !await repo.isKeptLocally(thumb)) {
        await repo.downloadEncrypted(thumb);
      }
      if (!await repo.hasLocalCopy(att)) {
        logger.info('No complete local copy, not signalling downloaded',
            tag: 'MediaRepository');
        return;
      }
      await repo.markDownloaded(ids.chatId, ids.messageId);
    } catch (e) {
      logger.info('markDownloaded skipped: $e', tag: 'MediaRepository');
    }
  }());
}

/// Stores/loads the *ciphertext* of media files in the private `media` bucket.
/// The plaintext bytes never reach here — they're AES-encrypted client-side
/// first, so this only moves opaque blobs.
class MediaRepository {
  final SupabaseClient client;

  /// The device's own encrypted copies (see [MediaBlobStore]).
  final MediaBlobStore store;

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

  MediaRepository(this.client, [this.store = const NoMediaBlobStore()]);

  /// Signal that the calling recipient has downloaded + decrypted a media blob.
  ///
  /// A media-retention signal DECOUPLED from read receipts (00056): the server
  /// reaps the blob once EVERY recipient has confirmed a download, so it no
  /// longer lingers for the read+7d window (or up to 3 months when receipts are
  /// off). Fire-and-forget + idempotent — callers swallow errors; the worst case
  /// is the blob waiting out the existing fallback windows.
  /// Reports "this device keeps a complete copy" (00092). Only that lets
  /// the server reap the blob; the older `mark_media_downloaded` no longer
  /// counts. Against a server without 00092 the call fails and is swallowed:
  /// the blob then simply stays until the fallback windows.
  Future<void> markDownloaded(String chatId, String messageId) =>
      client.rpc<void>(
        'mark_media_kept',
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
    await putRemote(
          path,
          blob,
          fileOptions: _fileOptions(kind),
        );
    // The sender keeps its own copy: once the recipients have theirs, the
    // server deletes the blob, and the sender's bubble needs it too.
    await _keep(path, blob);
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
    await putRemote(
          path,
          blob,
          // Tagged `video`, not `image`: a cover frame is storage that belongs
          // to a video message, and an operator asking how much space video
          // costs wants the poster counted with it. Tagging it `image` would
          // inflate the image count with objects no one ever sent.
          fileOptions: _fileOptions(MediaType.video),
        );
    await _keep(path, blob);
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
    await putRemote(
          path,
          blob,
          // Every chunk carries its parent attachment's kind, so a 400 MB video
          // counts as video across all ~67 of its objects rather than dropping
          // the largest files in the bucket into `unknown`.
          fileOptions: _fileOptions(kind),
        );
    await _keep(path, blob);
    return path;
  }

  /// Download an encrypted blob by its object path: the local copy if there
  /// is one, else from the server, kept locally on the way through.
  Future<Uint8List> downloadEncrypted(String path) async {
    try {
      final local = await store.read(path);
      if (local != null) return local;
    } catch (e) {
      logger.warning('Local media copy unreadable: $e', tag: 'MediaRepository');
    }
    final Uint8List blob;
    try {
      blob = await fetchRemote(path);
    } on StorageException catch (e) {
      if (isObjectGone(e)) throw MediaGoneException(path);
      rethrow;
    }
    await _keep(path, blob);
    return blob;
  }

  /// The server upload itself; separate so tests can stand in for it.
  Future<void> putRemote(String path, Uint8List blob,
          {required FileOptions fileOptions}) =>
      client.storage
          .from(bucket)
          .uploadBinary(path, blob, fileOptions: fileOptions);

  /// The server download itself; separate so tests can stand in for it.
  Future<Uint8List> fetchRemote(String path) =>
      client.storage.from(bucket).download(path);

  /// Best effort: a full disk costs the local copy, never the display. The
  /// downloaded signal checks [hasLocalCopy], so an unkept blob is never
  /// reported and the server keeps it.
  Future<void> _keep(String path, Uint8List blob) async {
    try {
      await store.write(path, blob);
    } catch (e) {
      logger.warning('Keeping media locally failed: $e', tag: 'MediaRepository');
    }
  }

  Future<bool> isKeptLocally(String path) async {
    try {
      return await store.contains(path);
    } catch (_) {
      return false;
    }
  }

  /// Every object [att] needs is stored locally: the blob or all its chunks,
  /// and a video's poster.
  Future<bool> hasLocalCopy(MediaAttachment att) async {
    final count = att.chunkCount;
    final paths = [
      if (count != null)
        for (var i = 0; i < count; i++) att.chunkPath(i)
      else
        att.path,
      if (att.thumbPath != null) att.thumbPath!,
    ];
    for (final p in paths) {
      if (!await isKeptLocally(p)) return false;
    }
    return true;
  }

  /// Best-effort delete (e.g. on send failure).
  Future<void> delete(String path) async {
    try {
      await client.storage.from(bucket).remove([path]);
    } catch (_) {}
  }
}

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  return MediaRepository(
    ref.read(supabaseClientProvider),
    ref.read(mediaBlobStoreProvider),
  );
});
