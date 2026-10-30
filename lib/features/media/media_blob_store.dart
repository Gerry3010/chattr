// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_blob_store_io.dart'
    if (dart.library.html) 'media_blob_store_web.dart';

/// The device's own copy of every media blob it has sent or received, kept
/// ENCRYPTED exactly as it travels through the `media` bucket. The key to
/// open it stays where it always was, in the message in the local database.
///
/// Why it exists: the server deletes a blob 24 h after every recipient has
/// reported it downloaded (00056), and until 2026-10-15 nothing on the device
/// kept it: every bubble downloaded and decrypted into memory, and dropped
/// the bytes again on scroll. Once the server had let go, the photo was gone
/// everywhere and its bubble spun forever. With this store, "downloaded"
/// means stored here, and only then is it reported.
///
/// Persistent storage on purpose (application support / IndexedDB), never a
/// cache directory the system may clear.
abstract class MediaBlobStore {
  Future<Uint8List?> read(String path);

  Future<void> write(String path, Uint8List blob);

  Future<bool> contains(String path);

  /// Every object of one message (a photo, its album siblings, a video's
  /// chunks and thumbnail): gone when the message is.
  Future<void> deleteMessage(String chatId, String messageId);

  /// `chatId/messageId` of everything stored, with when it was last written,
  /// for the orphan sweep.
  Future<Map<String, DateTime>> storedMessages();

  /// Logout / account switch.
  Future<void> clear();
}

/// A store that keeps nothing. Tests, and the fallback when the platform
/// store cannot be opened (then media behaves as before: server only).
class NoMediaBlobStore implements MediaBlobStore {
  const NoMediaBlobStore();

  @override
  Future<Uint8List?> read(String path) async => null;

  @override
  Future<void> write(String path, Uint8List blob) async {}

  @override
  Future<bool> contains(String path) async => false;

  @override
  Future<void> deleteMessage(String chatId, String messageId) async {}

  @override
  Future<Map<String, DateTime>> storedMessages() async => const {};

  @override
  Future<void> clear() async {}
}

final _uuid =
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _objectName = RegExp(r'^media-\d+(-thumb|-chunk-\d+)?\.enc$');

/// The storage path comes out of the SENDER's message, so it is the sender's
/// choice. Only the shape the app itself produces is stored:
/// `<chatId uuid>/<messageId uuid>/media-<n>[-thumb|-chunk-<k>].enc`. Anything
/// else (`../`, absolute paths, other names) is never written to disk.
bool isStorableMediaPath(String path) {
  final parts = path.split('/');
  return parts.length == 3 &&
      _uuid.hasMatch(parts[0]) &&
      _uuid.hasMatch(parts[1]) &&
      _objectName.hasMatch(parts[2]);
}

/// The platform store (files on native, IndexedDB-backed SQLite on web).
final mediaBlobStoreProvider =
    Provider<MediaBlobStore>((ref) => createMediaBlobStore());

/// For code without a ref (AppInit's logout wipe).
MediaBlobStore platformMediaBlobStore() => createMediaBlobStore();

/// Removes local copies whose message no longer exists on this device
/// (deleted, expired, chat left). [existingIds] answers which of the given
/// message ids are still in the local database.
///
/// Two brakes, because deleting here is final:
/// - Nothing younger than [minAge]: the sender stores its copy at upload,
///   before its message reaches the local database.
/// - Nothing at all when the database holds no messages or cannot be read:
///   a broken or not-yet-opened database must never look like "everything
///   was deleted".
Future<int> sweepOrphanMedia(
  MediaBlobStore store, {
  required Future<Set<String>> Function(Set<String> ids) existingIds,
  required Future<int> Function() messageCount,
  DateTime? now,
  Duration minAge = const Duration(hours: 24),
}) async {
  final stored = await store.storedMessages();
  if (stored.isEmpty) return 0;
  if (await messageCount() == 0) return 0;
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  final candidates = {
    for (final e in stored.entries)
      if (e.value.isBefore(cutoff)) e.key,
  };
  if (candidates.isEmpty) return 0;
  final keep = await existingIds({for (final c in candidates) c.split('/')[1]});
  var removed = 0;
  for (final c in candidates) {
    final parts = c.split('/');
    if (keep.contains(parts[1])) continue;
    await store.deleteMessage(parts[0], parts[1]);
    removed++;
  }
  return removed;
}
