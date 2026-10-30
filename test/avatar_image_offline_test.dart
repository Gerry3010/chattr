// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-63: without network there is no signed URL, and every avatar outside
// chatview fell back to initials although the picture sat in the disk cache.

import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/features/profiles/avatar_image.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';

/// Hands out a URL as if it had been minted, without a server.
class _MintedCache extends AvatarUrlCache {
  _MintedCache(this.url) : super(SupabaseClient('http://127.0.0.1:9', 'anon'));
  final String? url;

  @override
  String? cached(String bucket, String path) => url;

  @override
  void ensure(String bucket, String path) {}
}

void main() {
  const args = (bucket: kAvatarBucket, path: 'u1/0f1e.jpg');
  final png = Uint8List.fromList([137, 80, 78, 71]);

  tearDown(() => cachedAvatarBytesForTest = null);

  Future<ImageProvider?> resolve(ProviderContainer c) async {
    final sub = c.listen(avatarImageProvider(args), (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return c.read(avatarImageProvider(args));
  }

  test('offline kommt das Bild aus dem Cache, Schlüssel bucket/path', () async {
    String? asked;
    cachedAvatarBytesForTest = (key) async {
      asked = key;
      return png;
    };
    final c = ProviderContainer(overrides: [
      avatarUrlCacheProvider.overrideWith((ref) => _MintedCache(null)),
    ]);
    addTearDown(c.dispose);

    final image = await resolve(c);
    expect(asked, 'avatars/u1/0f1e.jpg');
    expect(image, isA<MemoryImage>());
  });

  test('offline und nichts im Cache: null, also Initialen', () async {
    cachedAvatarBytesForTest = (_) async => null;
    final c = ProviderContainer(overrides: [
      avatarUrlCacheProvider.overrideWith((ref) => _MintedCache(null)),
    ]);
    addTearDown(c.dispose);
    expect(await resolve(c), isNull);
  });

  test('online lädt es über die Adresse in denselben Cache-Eintrag', () async {
    const url = 'https://api.example/storage/v1/object/sign/avatars/u1/0f1e.jpg?token=x';
    final c = ProviderContainer(overrides: [
      avatarUrlCacheProvider.overrideWith((ref) => _MintedCache(url)),
    ]);
    addTearDown(c.dispose);
    final image = await resolve(c);
    expect(image, isA<CachedNetworkImageProvider>());
    expect((image! as CachedNetworkImageProvider).cacheKey,
        'avatars/u1/0f1e.jpg');
    expect(avatarCacheKeyForUrl(url), 'avatars/u1/0f1e.jpg',
        reason: 'derselbe Schlüssel wie im chatview-Fork');
  });

  test('kein Bild hochgeladen: null', () async {
    final c = ProviderContainer(overrides: [
      avatarUrlCacheProvider.overrideWith((ref) => _MintedCache('x')),
    ]);
    addTearDown(c.dispose);
    final sub = c.listen(
      avatarImageProvider((bucket: kAvatarBucket, path: '')),
      (_, _) {},
    );
    addTearDown(sub.close);
    expect(c.read(avatarImageProvider((bucket: kAvatarBucket, path: ''))),
        isNull);
  });
}
