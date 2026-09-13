// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:easy_video_editor/easy_video_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Reads a video's intrinsic DISPLAY dimensions so the sender can attach them to
/// the media envelope (#9) — the recipient then reserves the correctly-shaped
/// box before the bytes download and the gallery doesn't jump as the video
/// loads (mirrors [ImageMetadata.dimensions] for images).
///
/// Uses the native probe (easy_video_editor's `getVideoMetadata`), which is what
/// media_kit renders from too, so the numbers are ROTATION-CORRECT: a portrait
/// phone clip stored as landscape pixels + a 90°/270° rotation flag is reported
/// with width/height swapped to its upright display shape. Native only
/// (Android/iOS); returns null everywhere else or on any probe failure, so the
/// envelope stays additive/optional and the recipient falls back to guessing.
class VideoMetadataReader {
  VideoMetadataReader._();

  /// True only where the native video probe exists.
  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Display width/height of the video, or null if undeterminable. Prefers a
  /// [sourcePath] (no copy); falls back to spilling [bytes] to a temp file
  /// (small edited/trimmed clips) named with [tag] for uniqueness. Best-effort:
  /// never throws — a null result just means "no dimensions attached".
  static Future<({int width, int height})?> displayDimensions({
    Uint8List? bytes,
    String? sourcePath,
    required String tag,
  }) async {
    if (!_supported) return null;
    String? tempPath;
    try {
      final String path;
      if (sourcePath != null) {
        path = sourcePath;
      } else if (bytes != null) {
        final tmp = await getTemporaryDirectory();
        final safe = tag.replaceAll(RegExp(r'[^\w.\-]'), '_');
        final f = File('${tmp.path}/vdim_$safe.mp4');
        await f.writeAsBytes(bytes, flush: true);
        tempPath = f.path;
        path = f.path;
      } else {
        return null;
      }

      final meta = await VideoEditorBuilder(videoPath: path).getVideoMetadata();
      var w = meta.width;
      var h = meta.height;
      // A 90°/270° rotation flag means the stored pixels are sideways relative
      // to how they display — swap so the reserved box matches the player.
      if (meta.rotation % 180 == 90) {
        final t = w;
        w = h;
        h = t;
      }
      if (w <= 0 || h <= 0) return null;
      return (width: w, height: h);
    } catch (_) {
      return null; // never break sending over a dimension probe
    } finally {
      if (tempPath != null) {
        try {
          File(tempPath).deleteSync();
        } catch (_) {/* best-effort temp cleanup */}
      }
    }
  }
}
