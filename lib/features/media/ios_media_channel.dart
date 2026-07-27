// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/services.dart';

/// A video the native iOS PhotoKit shim materialized to a local temp file.
///
/// [path] is a file in the app's temporary directory — the caller MUST delete
/// it once the upload finishes.
class IosPickedVideo {
  final String path;
  final int size;
  final String name;
  final String? mime;
  final int? durationMs;
  const IosPickedVideo({
    required this.path,
    required this.size,
    required this.name,
    this.mime,
    this.durationMs,
  });
}

/// Bridge to the native iOS PhotoKit shim (Swift, in the Runner).
///
/// Why this exists: on iOS both `file_picker` and `image_picker` resolve a pick
/// through PHPicker's `NSItemProvider.loadFileRepresentation`, which FAILS for
/// clips that iCloud "Optimize Storage" has evicted from the device — it only
/// downloads them on first access, so the first pick throws "Cannot load
/// representation of type public.movie / public.mpeg-4". The native shim instead
/// takes the picked `assetIdentifier` → `PHAsset` and calls
/// `PHAssetResourceManager.writeData(isNetworkAccessAllowed: true)`, which
/// deterministically downloads the original bytes (no transcode) with progress
/// and hands back a guaranteed-local path.
///
/// iOS-only: callers gate on `Platform.isIOS`, so the channels are never invoked
/// elsewhere. The channel handles themselves compile on every platform, so no
/// web/desktop stub is needed. When the native side isn't in the build yet,
/// [pickGalleryVideo] throws [MissingPluginException] and the caller falls back
/// to the `image_picker` interim.
class IosMediaChannel {
  const IosMediaChannel._();

  static const MethodChannel _method = MethodChannel('chattr/ios_media');
  static const EventChannel _progressChannel =
      EventChannel('chattr/ios_media/progress');

  /// iCloud-download progress in `0.0..1.0`, emitted while a materialization is
  /// in flight. A fully-local asset emits little or nothing (it's instant).
  static Stream<double> get progress => _progressChannel
      .receiveBroadcastStream()
      .map((e) => (e as num).toDouble());

  /// Presents the native PHPicker (videos only, single select) and returns the
  /// materialized video, or `null` if the user cancels.
  ///
  /// [maxBytes] lets the native side reject an oversized clip BEFORE writing the
  /// temp file. Throws [PlatformException] with code `no_permission`,
  /// `icloud_failed`, or `too_large`; throws [MissingPluginException] when the
  /// native shim isn't in this build.
  static Future<IosPickedVideo?> pickGalleryVideo({int? maxBytes}) async {
    final res = await _method.invokeMapMethod<String, dynamic>(
      'pickGalleryVideo',
      {'maxBytes': maxBytes},
    );
    if (res == null) return null;
    return IosPickedVideo(
      path: res['path'] as String,
      size: (res['size'] as num).toInt(),
      name: res['name'] as String,
      mime: res['mime'] as String?,
      durationMs: (res['durationMs'] as num?)?.toInt(),
    );
  }
}
