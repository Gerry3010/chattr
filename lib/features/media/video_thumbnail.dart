// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:easy_video_editor/easy_video_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Generates a small JPEG cover frame for a video on the SEND side, so the
/// recipient can show a real thumbnail behind the play button (encrypted +
/// uploaded as its own tiny media object) instead of a black poster — without
/// ever downloading the whole (possibly chunked) video.
///
/// Native only (Android/iOS) via easy_video_editor's `generateThumbnail`;
/// returns null everywhere else or on any failure, so the cover frame is purely
/// additive (recipient falls back to the plain poster).
class VideoThumbnailer {
  VideoThumbnailer._();

  /// True only where the native thumbnail extractor exists.
  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Downscaled width of the generated cover frame — plenty for a poster, keeps
  /// the encrypted blob tiny.
  static const int _thumbWidth = 480;

  /// JPEG quality (0..100) — a poster tolerates aggressive compression.
  static const int _quality = 55;

  /// Encoded JPEG bytes of the video's cover frame, or null if unobtainable.
  /// Prefers a [sourcePath] (no copy); else spills [bytes] to a temp file
  /// (small edited/trimmed clips) named with [tag]. Best-effort: never throws.
  static Future<Uint8List?> generate({
    Uint8List? bytes,
    String? sourcePath,
    required String tag,
  }) async {
    if (!_supported) return null;
    String? tempIn;
    String? outPath;
    try {
      final String path;
      if (sourcePath != null) {
        path = sourcePath;
      } else if (bytes != null) {
        final tmp = await getTemporaryDirectory();
        final safe = tag.replaceAll(RegExp(r'[^\w.\-]'), '_');
        final f = File('${tmp.path}/vthumb_$safe.mp4');
        await f.writeAsBytes(bytes, flush: true);
        tempIn = f.path;
        path = f.path;
      } else {
        return null;
      }

      // First keyframe (positionMs 0) is cheapest and correct for the vast
      // majority of clips; exactFrame stays false so it snaps to a keyframe.
      outPath = await VideoEditorBuilder(videoPath: path).generateThumbnail(
        positionMs: 0,
        quality: _quality,
        width: _thumbWidth,
      );
      if (outPath == null) return null;
      final jpg = await File(outPath).readAsBytes();
      return jpg.isEmpty ? null : jpg;
    } catch (_) {
      return null; // never break sending over a thumbnail
    } finally {
      _deleteQuietly(tempIn);
      _deleteQuietly(outPath);
    }
  }

  static void _deleteQuietly(String? p) {
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {/* best-effort temp cleanup */}
  }
}
