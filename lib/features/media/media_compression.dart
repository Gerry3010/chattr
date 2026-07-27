// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

// Top-level so they qualify as compute() entry points. archive picks the
// platform codec itself: native zlib on IO, pure Dart on web — never import
// dart:io here.
Uint8List _gzipEncode(Uint8List bytes) =>
    const GZipEncoder().encodeBytes(bytes);

Uint8List _gzipDecode(Uint8List bytes) =>
    const GZipDecoder().decodeBytes(bytes);

/// Transparent gzip for file attachments: code/text/docs shrink a lot, while
/// photos/videos/archives are already compressed and are skipped. Correctness
/// comes from the size comparison in [maybeCompress]; the MIME skip list is
/// only a CPU shortcut. On web, compute() runs on the main isolate — jank is
/// bounded by [maxCompressAttemptBytes].
class MediaCompression {
  MediaCompression._();

  /// Value stored in the MediaAttachment `compression` field.
  static const String gzip = 'gzip';

  /// Don't even attempt to compress above this (CPU + RAM bound; large files
  /// are typically media anyway).
  static const int maxCompressAttemptBytes = 100 * 1024 * 1024;

  /// Keep the compressed result only if it saves at least this fraction.
  static const double _minSavings = 0.10;

  static const List<String> _skipPrefixes = [
    'image/',
    'video/',
    'audio/',
    // Office/OpenDocument containers are zip archives.
    'application/vnd.openxmlformats-',
    'application/vnd.oasis.opendocument',
  ];

  static const Set<String> _skipExact = {
    'application/zip',
    'application/gzip',
    'application/x-gzip',
    'application/x-7z-compressed',
    'application/x-rar-compressed',
    'application/vnd.rar',
    'application/x-xz',
    'application/x-bzip2',
    'application/pdf',
  };

  /// True when [mime] marks an already-compressed format not worth gzipping.
  @visibleForTesting
  static bool skipsMime(String mime) {
    final m = mime.toLowerCase();
    if (_skipExact.contains(m)) return true;
    return _skipPrefixes.any(m.startsWith);
  }

  /// Gzip [bytes] when it's worth it. Returns the compressed bytes, or null
  /// when the file should be sent raw (empty, too big, skipped MIME, or the
  /// savings are below 10%).
  static Future<Uint8List?> maybeCompress(Uint8List bytes, String mime) async {
    if (bytes.isEmpty || bytes.length > maxCompressAttemptBytes) return null;
    if (skipsMime(mime)) return null;
    final compressed = await compute(_gzipEncode, bytes);
    final maxUseful = bytes.length - (bytes.length * _minSavings).ceil();
    return compressed.length <= maxUseful ? compressed : null;
  }

  /// Inflate gzip [bytes], enforcing [maxBytes] on the output.
  ///
  /// The ISIZE trailer precheck plus the post-decode length check guard
  /// against honest bugs and naive decompression bombs. ISIZE is forgeable
  /// (mod 2^32) by a malicious sender with a custom client — accepted risk,
  /// since senders are already trusted E2E chat members; archive 4.x offers
  /// no way to abort mid-inflate.
  static Future<Uint8List> decompress(
    Uint8List bytes, {
    required int maxBytes,
  }) async {
    // gzip minimum: 10-byte header + 8-byte trailer (CRC32 + ISIZE).
    if (bytes.length < 18) {
      throw const FormatException('gzip data too short');
    }
    final isize = ByteData.sublistView(bytes, bytes.length - 4)
        .getUint32(0, Endian.little);
    if (isize > maxBytes) {
      throw FormatException(
        'gzip claims $isize bytes, exceeding the $maxBytes limit',
      );
    }
    final out = await compute(_gzipDecode, bytes);
    if (out.length > maxBytes) {
      throw FormatException(
        'decompressed to ${out.length} bytes, exceeding the $maxBytes limit',
      );
    }
    return out;
  }
}
