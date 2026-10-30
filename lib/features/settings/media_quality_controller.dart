// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// How photos and videos are sent: at full resolution or downscaled.
///
/// **The default is [MediaQuality.original], and that is the heart of the
/// matter.** A messenger that shrinks pictures unasked takes a decision away
/// that nobody asked it to take — one notices only later, when one wants to
/// enlarge the photo and cannot. Whoever wants to save data says so; whoever
/// says nothing gets their picture the way they took it.
///
/// **Local only.** It is a preference of this device (data allowance, storage),
/// not a property of the account — and the server learns only how large the
/// ciphertext is anyway, not why.
enum MediaQuality {
  /// Send unchanged — full resolution.
  original,

  /// Downscale before sending (images to the long edge, videos to 720p).
  smaller,
}

/// The stored default. The send sheet may override it **for one send** without
/// changing it.
final mediaQualityProvider =
    StateNotifierProvider<MediaQualityController, MediaQuality>((ref) {
  return MediaQualityController(ref.read(secureStorageProvider));
});

class MediaQualityController extends StateNotifier<MediaQuality> {
  static const _storageKey = 'media_quality_v1';

  final FlutterSecureStorage _storage;

  /// Completes as soon as the stored value has been read. `state` holds the
  /// default immediately so the UI has nothing to wait for — but the **send
  /// path** must await [resolvedValue]. Otherwise, on the first send after a
  /// cold start, the default wins the race against loading, and a user who has
  /// set "smaller" sends their video at full size after all. The same trap as
  /// with the read receipts (`read_receipts_controller`).
  final Completer<void> _loaded = Completer<void>();

  MediaQualityController(this._storage) : super(MediaQuality.original) {
    _init();
  }

  Future<void> _init() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      // Only an explicit 'smaller' switches over — a missing or unreadable
      // value means full quality.
      if (mounted && raw == MediaQuality.smaller.name) {
        state = MediaQuality.smaller;
      }
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  /// The stored value once loading is complete — for the send path. For display
  /// the synchronous `state` suffices.
  Future<MediaQuality> resolvedValue() async {
    await _loaded.future;
    return state;
  }

  Future<void> setQuality(MediaQuality quality) async {
    await _storage.write(key: _storageKey, value: quality.name);
    state = quality;
  }

  Future<void> setSmaller(bool smaller) =>
      setQuality(smaller ? MediaQuality.smaller : MediaQuality.original);
}
