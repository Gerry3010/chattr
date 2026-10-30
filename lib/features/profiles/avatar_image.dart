// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'avatar_url_cache.dart';

/// The picture for an avatar object, from the network or from the disk.
///
/// Online it loads through the signed URL into the disk cache, keyed by
/// `bucket/path`, the same key the chatview fork uses (p25). Without a URL,
/// offline or before one is minted, it shows what the device already has
/// under that key (CHAT-63). Before, every avatar outside chatview used a
/// plain `NetworkImage`, and without network all of them fell back to
/// initials.
///
/// No extra timestamp is needed to notice a new picture: every upload gets a
/// fresh object name (CHAT-23), so a new picture is a new path and a new key.
///
/// Null while there is nothing to show; callers draw their initials then.
final avatarImageProvider = Provider.autoDispose
    .family<ImageProvider?, ({String bucket, String path})>((ref, args) {
  if (args.path.isEmpty) return null;
  final key = AvatarUrlCache.keyFor(args.bucket, args.path);
  final url = ref.watch(avatarSignedUrlProvider(args));
  if (url != null) return CachedNetworkImageProvider(url, cacheKey: key);
  final bytes = ref.watch(_cachedAvatarBytesProvider(key)).value;
  return bytes == null ? null : MemoryImage(bytes);
});

/// Seam for tests: the cache manager is a singleton with a database behind it.
@visibleForTesting
Future<Uint8List?> Function(String key)? cachedAvatarBytesForTest;

final _cachedAvatarBytesProvider =
    FutureProvider.autoDispose.family<Uint8List?, String>((ref, key) async {
  final seam = cachedAvatarBytesForTest;
  if (seam != null) return seam(key);
  try {
    final info = await DefaultCacheManager().getFileFromCache(key);
    return await info?.file.readAsBytes();
  } catch (_) {
    // No cache on this platform, or the file vanished: initials it is.
    return null;
  }
});
