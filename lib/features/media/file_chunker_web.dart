// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

/// Web stub: the browser has no file paths (web picks always come as in-memory
/// bytes), so this is never reached on web. Throws if ever called.
Future<Uint8List> readFileBytes(String sourcePath) async {
  throw UnsupportedError('File-path reads are unavailable on web');
}

/// Web stub: the browser has no file paths, so large chunked sends never take
/// this path (web picks always come as in-memory bytes). Throws if ever called.
Future<int> forEachFileChunk(
  String sourcePath,
  int chunkSize,
  Future<void> Function(int chunkIndex, int chunkCount, Uint8List chunk) onChunk,
) async {
  throw UnsupportedError('Chunked file streaming is unavailable on web');
}
