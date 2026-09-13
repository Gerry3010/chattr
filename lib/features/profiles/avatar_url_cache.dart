// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';

/// Buckets holding avatars. Both are private (00075) — an object is only
/// reachable through a signed URL minted for a signed-in member.
const String kAvatarBucket = 'avatars';
const String kGroupAvatarBucket = 'group-avatars';

/// How long a minted URL stays valid.
///
/// Short on purpose: a link that leaks (a screenshot, a log, a shared debug
/// bundle) stops working within the hour, which is the whole difference
/// between this and the permanently public URLs it replaces.
const Duration kAvatarUrlTtl = Duration(hours: 1);

/// Mint a fresh one this long before expiry, so a picture never blinks out
/// mid-session.
const Duration kAvatarUrlRefreshMargin = Duration(minutes: 10);

@immutable
class _SignedUrl {
  const _SignedUrl(this.url, this.expiresAt);

  final String url;
  final DateTime expiresAt;

  bool staleAt(DateTime now) =>
      now.isAfter(expiresAt.subtract(kAvatarUrlRefreshMargin));
}

/// Signed avatar URLs, kept in memory and refreshed before they expire.
///
/// Only in memory: writing them to disk would defeat the point of a short
/// lifetime, and minting one is a single cheap call.
///
/// The state is keyed `bucket/path`, which is also the **stable identity** of
/// the picture. Every image cache in the app keys on that instead of the URL —
/// otherwise each refreshed signature would read as a brand-new image, be
/// downloaded again, and pile up cache files without bound.
class AvatarUrlCache extends StateNotifier<Map<String, String>> {
  AvatarUrlCache(this._client) : super(const {});

  final SupabaseClient _client;

  final Map<String, _SignedUrl> _signed = {};
  final Set<String> _inFlight = {};

  static String keyFor(String bucket, String path) => '$bucket/$path';

  /// The URL for [path] if we have a usable one, else null.
  ///
  /// Never blocks and never mints — a widget calls this during build. When it
  /// returns null (or the URL is about to expire) [ensure] does the fetching
  /// and the state update rebuilds the watcher.
  String? cached(String bucket, String path) {
    final entry = _signed[keyFor(bucket, path)];
    if (entry == null) return null;
    return entry.expiresAt.isAfter(DateTime.now()) ? entry.url : null;
  }

  /// Make sure a usable URL for [path] exists, minting one if needed.
  void ensure(String bucket, String path) {
    final key = keyFor(bucket, path);
    final entry = _signed[key];
    if (entry != null && !entry.staleAt(DateTime.now())) return;
    if (!_inFlight.add(key)) return;
    unawaited(_mint(bucket, [path]).whenComplete(() => _inFlight.remove(key)));
  }

  /// Mint URLs for many objects at once — one round trip instead of one per
  /// row. Called when a screen knows its whole set of avatars up front (the
  /// chat list, a member list), so nothing has to be fetched while scrolling.
  Future<void> prefetch(String bucket, Iterable<String> paths) async {
    final now = DateTime.now();
    final wanted = paths
        .where((p) => p.isNotEmpty)
        .where((p) {
          final entry = _signed[keyFor(bucket, p)];
          return entry == null || entry.staleAt(now);
        })
        .toSet()
        .where((p) => _inFlight.add(keyFor(bucket, p)))
        .toList();
    if (wanted.isEmpty) return;
    try {
      await _mint(bucket, wanted);
    } finally {
      for (final p in wanted) {
        _inFlight.remove(keyFor(bucket, p));
      }
    }
  }

  Future<void> _mint(String bucket, List<String> paths) async {
    try {
      final seconds = kAvatarUrlTtl.inSeconds;
      final expiresAt = DateTime.now().add(kAvatarUrlTtl);
      final storage = _client.storage.from(bucket);

      final Map<String, String> fresh = {};
      if (paths.length == 1) {
        fresh[paths.first] = await storage.createSignedUrl(paths.first, seconds);
      } else {
        // ...Result, not the deprecated overload: it reports a missing object
        // as its own case instead of dropping it silently, which matters here
        // because a stale `avatar_path` is exactly the expected failure.
        for (final row in await storage.createSignedUrlsResult(paths, seconds)) {
          if (row is SignedUrlSuccess && row.signedUrl.isNotEmpty) {
            fresh[row.path] = row.signedUrl;
          }
        }
      }

      for (final entry in fresh.entries) {
        _signed[keyFor(bucket, entry.key)] = _SignedUrl(entry.value, expiresAt);
      }
      if (!mounted || fresh.isEmpty) return;
      state = {
        ...state,
        for (final entry in fresh.entries)
          keyFor(bucket, entry.key): entry.value,
      };
    } catch (e) {
      // A missing object (a stale avatar_path) throws here. Never fatal: the
      // avatar falls back to the initials circle, which is a fine outcome.
      logger.warning(
        'Could not sign ${paths.length} avatar url(s) in $bucket: $e',
        tag: 'AvatarUrlCache',
      );
    }
  }

  /// Drop everything — used when the session ends, so URLs minted for the old
  /// account cannot outlive it in memory.
  void clear() {
    _signed.clear();
    _inFlight.clear();
    if (mounted) state = const {};
  }
}

final avatarUrlCacheProvider =
    StateNotifierProvider<AvatarUrlCache, Map<String, String>>((ref) {
  return AvatarUrlCache(ref.read(supabaseClientProvider));
});

/// A usable signed URL for an avatar object path, or null while there is none.
///
/// Watch this from a widget: it returns null on the first build (the initials
/// circle shows, which every avatar widget already handles) and rebuilds once
/// the URL arrives. Same shape as `profileProvider` — schedule the work, serve
/// what is known.
final avatarSignedUrlProvider =
    Provider.autoDispose.family<String?, ({String bucket, String path})>(
  (ref, args) {
    final cache = ref.watch(avatarUrlCacheProvider.notifier);
    // Watching the map is what re-runs this provider when a URL arrives.
    ref.watch(avatarUrlCacheProvider);
    if (args.path.isEmpty) return null;

    // Scheduled, not awaited: a provider body must not do I/O.
    Future.microtask(() => cache.ensure(args.bucket, args.path));
    return cache.cached(args.bucket, args.path);
  },
);

/// The stable cache key behind a signed avatar URL — `bucket/path`, with the
/// signature stripped.
///
/// Handed to `ProfileImageWidget.cacheKeyResolver` (fork p25) and used by the
/// share-suggestion avatar cache, so both keep ONE file per picture instead of
/// one per signature.
String? avatarCacheKeyForUrl(String url) {
  const marker = '/storage/v1/object/sign/';
  final start = url.indexOf(marker);
  if (start < 0) return null;
  final rest = url.substring(start + marker.length);
  final query = rest.indexOf('?');
  return query < 0 ? rest : rest.substring(0, query);
}
