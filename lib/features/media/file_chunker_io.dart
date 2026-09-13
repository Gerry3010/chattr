// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

/// Reads the whole file at [sourcePath] into memory. Used for a SMALL file-path
/// source that takes the non-chunked send path (e.g. a trimmed video below the
/// chunk threshold) — large sources stream via [forEachFileChunk] instead.
Future<Uint8List> readFileBytes(String sourcePath) =>
    File(sourcePath).readAsBytes();

/// Reads [sourcePath] in fixed [chunkSize] plaintext blocks and invokes
/// [onChunk] for each — with its 0-based index and the total [chunkCount] —
/// awaiting each callback before reading on. Only ~one chunk is resident at a
/// time (peak ≈ chunkSize + the callback's ciphertext copy). Returns the total
/// number of chunks. An empty file yields exactly one empty chunk (count 1).
Future<int> forEachFileChunk(
  String sourcePath,
  int chunkSize,
  Future<void> Function(int chunkIndex, int chunkCount, Uint8List chunk) onChunk,
) async {
  final file = File(sourcePath);
  final total = await file.length();
  final chunkCount = total == 0 ? 1 : (total + chunkSize - 1) ~/ chunkSize;
  var index = 0;
  final builder = BytesBuilder(copy: false);

  Future<void> emit(Uint8List chunk) async {
    await onChunk(index, chunkCount, chunk);
    index++;
  }

  await for (final piece in file.openRead()) {
    builder.add(piece);
    while (builder.length >= chunkSize) {
      final all = builder.takeBytes();
      await emit(Uint8List.sublistView(all, 0, chunkSize));
      if (all.length > chunkSize) {
        builder.add(Uint8List.sublistView(all, chunkSize));
      }
    }
  }
  // Trailing partial chunk, or a single empty chunk for a 0-byte file.
  if (builder.length > 0 || index == 0) {
    await emit(builder.takeBytes());
  }
  return chunkCount;
}
