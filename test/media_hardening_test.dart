// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Audit M9: media storage object paths must be OPAQUE — the user's filename
// must never appear in the bucket path (it leaks to anyone who can list the
// bucket). The real name lives only in the per-recipient-encrypted descriptor.

import 'package:chattr/features/media/media_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MediaRepository.objectPath (M9 opaque names)', () {
    const chatId = '11111111-1111-1111-1111-111111111111';
    const messageId = '22222222-2222-2222-2222-222222222222';

    test('path is <chatId>/<messageId>/media-<index>.enc — no filename', () {
      expect(
        MediaRepository.objectPath(chatId, messageId),
        '$chatId/$messageId/media-0.enc',
      );
      // Album objects (#109) stay under the same messageId folder, indexed.
      expect(
        MediaRepository.objectPath(chatId, messageId, index: 3),
        '$chatId/$messageId/media-3.enc',
      );
    });

    test('album object paths are unique and share the messageId folder (#109)',
        () {
      final paths = [
        for (var i = 0; i < 5; i++)
          MediaRepository.objectPath(chatId, messageId, index: i),
      ];
      expect(paths.toSet(), hasLength(5)); // all distinct
      for (final p in paths) {
        final parts = p.split('/');
        // Reaper (00034) keys on segment[1] = messageId → all reaped as a group.
        expect(parts[1], messageId);
      }
    });

    test('a sensitive filename never leaks into the path', () {
      // Whatever the file was called, the path is identical + opaque.
      final path = MediaRepository.objectPath(chatId, messageId);
      for (final leaky in [
        'Reisepass_Scan',
        'gehaltsabrechnung',
        'IMG_20260716_nudes',
        'Bewerbung Max Mustermann',
      ]) {
        expect(path.toLowerCase().contains(leaky.toLowerCase()), isFalse);
      }
    });

    test('reaper-relevant segments (chatId, messageId) are preserved', () {
      // Migration 00034 keys the media reaper on split_part(name,'/',2) =
      // messageId, so those segments must stay put.
      final parts = MediaRepository.objectPath(chatId, messageId).split('/');
      expect(parts[0], chatId);
      expect(parts[1], messageId);
      expect(parts[2], 'media-0.enc');
    });

    test('chunk object paths are unique + share the messageId folder (chunking)',
        () {
      final paths = [
        for (var c = 0; c < 4; c++)
          MediaRepository.chunkObjectPath(chatId, messageId,
              attIndex: 0, chunkIndex: c),
      ];
      expect(paths.toSet(), hasLength(4)); // all distinct
      for (final p in paths) {
        // Reaper (00034) keys on segment[1] = messageId → chunks reaped as a
        // group with the message, no migration needed.
        expect(p.split('/')[1], messageId);
      }
      // The descriptor stores the PREFIX; MediaAttachment.chunkPath appends the
      // same suffix the repo uploads to — they must agree.
      final prefix =
          MediaRepository.chunkPrefixPath(chatId, messageId, attIndex: 0);
      expect(
        '$prefix-chunk-2.enc',
        MediaRepository.chunkObjectPath(chatId, messageId,
            attIndex: 0, chunkIndex: 2),
      );
    });
  });
}
