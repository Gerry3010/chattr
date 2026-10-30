// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../core/security/message_encryption_service.dart';
import 'decrypted_media_server.dart';
import 'media_attachment.dart';
import 'media_cache_io.dart' show mediaCacheDirName;
import 'media_repository.dart';

/// A playable media URI backed by a temporary decrypted file on disk.
///
/// Video engines (media_kit/libmpv, video_player) cannot play directly from an
/// in-memory [Uint8List] on native platforms — they need a file path or URL. So
/// we decrypt to a short-lived file in the app's private temp-cache dir and
/// delete it as soon as the player is torn down (decrypt-to-cache, the standard
/// pattern for E2E media apps).
class VideoSource {
  /// File path — or, when streaming, the loopback address of the
  /// [DecryptedMediaServer] — that media_kit can open.
  final String uri;
  final File? _file;
  final DecryptedMediaServer? _server;

  VideoSource._(this.uri, this._file, [this._server]);

  /// Plays a **chunked** medium WHILE it is still loading (1.27).
  ///
  /// Instead of fetching, decrypting and writing everything to disk first, the
  /// player opens a local address and gets the blocks as soon as they are there
  /// and verified. Playback therefore starts after the FIRST block, not after
  /// the last — and no decrypted file comes into being on disk at all any more.
  ///
  /// Why only for chunked media: see [DecryptedMediaServer]. With a single
  /// object the checksum sits at the end; playing earlier would mean displaying
  /// unverified data.
  static Future<VideoSource> streaming(
    MediaAttachment attachment,
    MediaRepository repo,
    MessageEncryptionService svc,
  ) async {
    final server = await DecryptedMediaServer.start(
      attachment: attachment,
      repo: repo,
      svc: svc,
    );
    return VideoSource._(server.uri, null, server);
  }

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
    await _server?.dispose();
    final file = _file;
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Best-effort cleanup — a leftover temp file is not fatal.
    }
  }
}
