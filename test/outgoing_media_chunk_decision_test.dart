// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Item 1 (1.9): large-file chunking is no longer restricted to videos. The send
// controller chunks any item whose plaintext lives on disk and exceeds the
// threshold (`sourcePath != null && size > chunkThresholdBytes`) — mime-agnostic.
// These tests pin that invariant so a future change can't silently re-narrow the
// chunked path back to video-only.

import 'dart:typed_data';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirrors the controller's `isChunked(f)` closure (messages_controller.dart).
  bool wouldChunk(OutgoingMedia f) =>
      f.sourcePath != null && f.size > MediaRepository.chunkThresholdBytes;

  final bigSize = MediaRepository.chunkThresholdBytes + 1;

  test('large NON-video path-backed files take the chunked path', () {
    for (final mime in [
      'application/zip',
      'application/pdf',
      'application/octet-stream',
      'audio/mpeg',
    ]) {
      final f = OutgoingMedia.file('/tmp/big.bin',
          size: bigSize, fileName: 'big.bin', mime: mime);
      expect(wouldChunk(f), isTrue, reason: '$mime over threshold must chunk');
    }
  });

  test('large videos still chunk (no regression)', () {
    final f = OutgoingMedia.file('/tmp/clip.mp4',
        size: bigSize, fileName: 'clip.mp4', mime: 'video/mp4');
    expect(wouldChunk(f), isTrue);
  });

  test('small path-backed files stay on the bytes path', () {
    final f = OutgoingMedia.file('/tmp/small.pdf',
        size: MediaRepository.chunkThresholdBytes - 1,
        fileName: 'small.pdf',
        mime: 'application/pdf');
    expect(wouldChunk(f), isFalse);
  });

  test('in-memory (web/pathless) sources are never chunked', () {
    final f = OutgoingMedia.bytes(Uint8List(bigSize),
        fileName: 'big.zip', mime: 'application/zip');
    expect(wouldChunk(f), isFalse, reason: 'no sourcePath → cannot stream');
  });
}
