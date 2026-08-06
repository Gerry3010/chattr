// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A playable media URI backed by an in-memory Blob object URL (no disk).
///
/// On web, media_kit opens a `blob:` URL just like a network URL, so the
/// decrypted bytes never touch disk. The object URL is revoked on dispose.
class VideoSource {
  /// Blob object URL media_kit can open.
  final String uri;

  VideoSource._(this.uri);

  static Future<VideoSource> create(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    return VideoSource._(web.URL.createObjectURL(blob));
  }

  /// Collects decrypted chunks into an in-memory Blob (web has no file paths;
  /// desktop RAM makes this acceptable). Revoked on [dispose].
  static Future<VideoSource> fromChunkStream(
    Stream<Uint8List> chunks,
    String fileName,
    String mimeType,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in chunks) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    return VideoSource._(web.URL.createObjectURL(blob));
  }

  Future<void> dispose() async {
    web.URL.revokeObjectURL(uri);
  }
}
