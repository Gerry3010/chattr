// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/logger_service.dart';

/// Puts an avatar on disk so the OS can show it in the share-sheet suggestion
/// row.
///
/// **Why this exists.** Both native donation paths want a FILE — iOS builds an
/// `INImage` from one, Android an adaptive icon. Chattr avatars are plain
/// network URLs rendered through `NetworkImage`, which caches in memory only, so
/// there was never a path to hand over. `ShareRecipient.avatarPath` was
/// therefore always null and every suggestion showed a blank circle next to
/// WhatsApp's photo (seen 2026-08-05).
///
/// **What it must not do.** A donation happens on EVERY send. Downloading an
/// avatar each time would hang a network round-trip off the send path, so a hit
/// is a single `File.exists` and nothing else. Misses download once per URL and
/// are then permanent for that URL — avatar changes carry a fresh path (and the
/// group URL a cache-busting query), so a new picture is simply a new key.
///
/// **Everything here is best-effort.** No network, no permission, a corrupt
/// response, an unwritable cache — all end in `null`, which is exactly the state
/// the feature had before. The suggestion still works, it just has no picture.
class ShareSuggestionAvatarCache {
  const ShareSuggestionAvatarCache._();

  /// Subdirectory under the app cache. Its own folder so [clear] can drop
  /// everything without touching another feature's files.
  static const String _dirName = 'share_suggestion_avatars';

  /// Cap on a downloaded avatar. Avatars are small; anything larger is either
  /// not an avatar or not worth putting on the send path. The bucket is public,
  /// so this is also the bound on what a hostile URL could make us write.
  static const int _maxBytes = 2 * 1024 * 1024;

  /// In-memory memo of URL → path (or null for "we tried and it failed"), so a
  /// chat sent to repeatedly does not even stat the file system again.
  static final Map<String, String?> _memo = <String, String?>{};

  /// Test seam for the one thing a unit test cannot supply: the network.
  /// Null in every real build, so production always uses [http.get].
  @visibleForTesting
  static http.Client? debugClient;

  /// Local file for [url], downloading it once. Null when there is no URL, the
  /// platform has no file system, or anything at all goes wrong.
  static Future<String?> pathFor(String? url) async {
    if (kIsWeb || url == null || url.isEmpty) return null;
    if (_memo.containsKey(url)) return _memo[url];
    final path = await _resolve(url);
    _memo[url] = path;
    return path;
  }

  static Future<String?> _resolve(String url) async {
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/$_dirName',
      );
      // The file name is a hash of the URL, never a piece of it: the URL
      // contains the uploader's user id, and a cache file name is the kind of
      // thing that ends up in a crash log.
      final file = File(
        '${dir.path}/${sha256.convert(utf8.encode(url)).toString()}',
      );
      if (file.existsSync()) return file.path;

      final client = debugClient;
      final res = await (client == null
              ? http.get(Uri.parse(url))
              : client.get(Uri.parse(url)))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxBytes) return null;

      await dir.create(recursive: true);
      // Write beside the target and rename, so a download interrupted halfway
      // can never leave a truncated file that we would then treat as a hit
      // forever (rename is atomic on the same filesystem).
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      return file.path;
    } catch (e) {
      logger.warning(
        'Share-suggestion avatar not cached: $e',
        tag: 'ShareSuggestions',
      );
      return null;
    }
  }

  /// Drop every cached avatar. Called alongside `deleteAll()` — once the
  /// donations are gone, keeping the pictures that fed them would leave exactly
  /// the trace the deletion was meant to remove.
  static Future<void> clear() async {
    _memo.clear();
    if (kIsWeb) return;
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/$_dirName',
      );
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      logger.warning(
        'Share-suggestion avatar cache not cleared: $e',
        tag: 'ShareSuggestions',
      );
    }
  }

  /// Test seam: forget the in-memory memo without touching disk.
  static void debugResetMemo() => _memo.clear();
}
