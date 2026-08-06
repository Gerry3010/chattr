// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'media_cache_io.dart' show mediaCacheDirName;

/// A playable media URI backed by a temporary decrypted file on disk.
///
/// Video engines (media_kit/libmpv, video_player) cannot play directly from an
/// in-memory [Uint8List] on native platforms — they need a file path or URL. So
/// we decrypt to a short-lived file in the app's private temp-cache dir and
/// delete it as soon as the player is torn down (decrypt-to-cache, the standard
/// pattern for E2E media apps).
class VideoSource {
  /// File path media_kit can open.
  final String uri;
  final File _file;

  VideoSource._(this.uri, this._file);

  static Future<VideoSource> create(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) async {
    final dir = await getTemporaryDirectory();
    final cache = Directory('${dir.path}/$mediaCacheDirName');
    if (!cache.existsSync()) cache.createSync(recursive: true);
    // Prefix keeps the original extension so libmpv can sniff the container.
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${cache.path}/${DateTime.now().microsecondsSinceEpoch}_$safe');
    await file.writeAsBytes(bytes, flush: true);
    return VideoSource._(file.path, file);
  }

  /// Streams decrypted chunks straight to the temp-cache file without ever
  /// holding the whole video in memory (chunked media). Same lifecycle as
  /// [create] — the file is deleted on [dispose].
  static Future<VideoSource> fromChunkStream(
    Stream<Uint8List> chunks,
    String fileName,
    String mimeType,
  ) async {
    final dir = await getTemporaryDirectory();
    final cache = Directory('${dir.path}/$mediaCacheDirName');
    if (!cache.existsSync()) cache.createSync(recursive: true);
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file =
        File('${cache.path}/${DateTime.now().microsecondsSinceEpoch}_$safe');
    final sink = file.openWrite();
    try {
      await for (final chunk in chunks) {
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return VideoSource._(file.path, file);
  }

  Future<void> dispose() async {
    try {
      if (_file.existsSync()) await _file.delete();
    } catch (_) {
      // Best-effort cleanup — a leftover temp file is not fatal.
    }
  }
}
