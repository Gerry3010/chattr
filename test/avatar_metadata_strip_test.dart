// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Metadaten-Audit 2026-08-02 (D4): chat media was EXIF-stripped since the L6
// audit fix, but AVATARS were not — user and group pictures went into a
// **public** bucket raw, carrying GPS coordinates, device model and capture
// time. Group avatars can come straight from the camera, so that was the
// capture location.
//
// The strip now lives in the repositories (the choke point). This is a
// structural guard so a future third upload path can't silently reintroduce
// the same bug: every `uploadBinary` call site must either sanitize its bytes
// or be an explicitly justified exception.
//
//   flutter test test/avatar_metadata_strip_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Upload sites that legitimately do NOT strip here, with the reason.
const Map<String, String> _justifiedExceptions = {
  // Media blobs are encrypted before upload; the plaintext went through
  // ImageMetadata.normalizeAndStrip in MessagesController._uploadSingleMedia.
  // Stripping ciphertext would be meaningless (and would corrupt it).
  'lib/features/media/media_repository.dart':
      'uploads already-encrypted blobs; plaintext is stripped before encryption',
};

void main() {
  test('every storage upload path either strips metadata or is justified', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'run from the package root');

    final offenders = <String>[];

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (!source.contains('uploadBinary(')) continue;

      final relative = entity.path;
      if (_justifiedExceptions.containsKey(relative)) continue;

      if (!source.contains('ImageMetadata.normalizeAndStrip')) {
        offenders.add(relative);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These files upload bytes to storage without stripping image '
          'metadata. Either call ImageMetadata.normalizeAndStrip on the bytes, '
          'or add the file to _justifiedExceptions with a reason.',
    );
  });

  test('the exception list itself still points at real files', () {
    // Keeps the allow-list from silently going stale after a rename — a stale
    // entry would mean a genuinely unchecked path slips through unnoticed.
    for (final path in _justifiedExceptions.keys) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'stale exception entry: $path no longer exists',
      );
    }
  });
}
