// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Chunked large-media encryption (backlog large-file-chunking). Each chunk of a
// big file is encrypted independently with the file's media key + a per-chunk
// AAD that binds its position, so a malicious server can't reorder, drop,
// truncate, duplicate, splice-in, or tamper chunks without a decrypt failure.

import 'dart:math';
import 'dart:typed_data';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  final svc =
      MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));

  const messageId = '11111111-2222-3333-4444-555555555555';
  const attIndex = 0;

  Uint8List chunkData(int i, int len) {
    final rng = Random(i + 1);
    return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
  }

  test('chunk roundtrips with matching key + AAD', () async {
    final key = svc.newMediaKey();
    expect(key.length, 32);
    const count = 4;
    final chunks = [for (var i = 0; i < count; i++) chunkData(i, 5000)];

    final blobs = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      blobs.add(await svc.encryptChunk(chunks[i], key,
          aad: MessageEncryptionService.mediaChunkAad(
              messageId, attIndex, i, count)));
      // Self-contained framing: nonce(12) + ct + tag(16) → longer than input.
      expect(blobs[i].length, greaterThan(chunks[i].length));
    }

    for (var i = 0; i < count; i++) {
      final plain = await svc.decryptChunk(blobs[i], key,
          aad: MessageEncryptionService.mediaChunkAad(
              messageId, attIndex, i, count));
      expect(plain, equals(chunks[i]));
    }
  });

  // Blobs >=256 KiB are decrypted on a background isolate (compute); make sure
  // that off-thread path stays byte-identical AND keeps enforcing the AAD.
  test('large chunk roundtrips via the off-thread decrypt path', () async {
    final key = svc.newMediaKey();
    final big = chunkData(7, 300 * 1024); // > _offThreadDecryptThreshold
    final aad = MessageEncryptionService.mediaChunkAad(messageId, 0, 0, 1);
    final blob = await svc.encryptChunk(big, key, aad: aad);
    final plain = await svc.decryptChunk(blob, key, aad: aad);
    expect(plain, equals(big));
  });

  test('large chunk with wrong AAD fails off-thread too', () async {
    final key = svc.newMediaKey();
    final big = chunkData(8, 300 * 1024);
    final blob = await svc.encryptChunk(big, key,
        aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 0, 2));
    expect(
      () => svc.decryptChunk(blob, key,
          aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 1, 2)),
      throwsA(anything),
    );
  });

  test('reordering chunks fails (AAD chunkIndex mismatch)', () async {
    final key = svc.newMediaKey();
    const count = 3;
    final b0 = await svc.encryptChunk(chunkData(0, 4000), key,
        aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 0, count));
    // Decrypt chunk 0's blob but claim it is at index 1 → must throw.
    expect(
      () => svc.decryptChunk(b0, key,
          aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 1, count)),
      throwsA(anything),
    );
  });

  test('truncation changes chunkCount in AAD → fails', () async {
    final key = svc.newMediaKey();
    // Encrypted as part of a 5-chunk file...
    final b = await svc.encryptChunk(chunkData(2, 4000), key,
        aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 2, 5));
    // ...a server claiming the file has only 3 chunks can't pass it off.
    expect(
      () => svc.decryptChunk(b, key,
          aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 2, 3)),
      throwsA(anything),
    );
  });

  test('splicing a chunk from another message fails (AAD messageId)', () async {
    final key = svc.newMediaKey();
    final b = await svc.encryptChunk(chunkData(0, 4000), key,
        aad: MessageEncryptionService.mediaChunkAad(messageId, 0, 0, 2));
    expect(
      () => svc.decryptChunk(b, key,
          aad: MessageEncryptionService.mediaChunkAad(
              '99999999-8888-7777-6666-555555555555', 0, 0, 2)),
      throwsA(anything),
    );
  });

  test('tampering the ciphertext fails the GCM tag', () async {
    final key = svc.newMediaKey();
    final aad = MessageEncryptionService.mediaChunkAad(messageId, 0, 0, 1);
    final b = await svc.encryptChunk(chunkData(0, 4000), key, aad: aad);
    final tampered = Uint8List.fromList(b)..[20] ^= 0xFF; // flip a ct byte
    expect(() => svc.decryptChunk(tampered, key, aad: aad), throwsA(anything));
  });

  test('wrong media key fails', () async {
    final aad = MessageEncryptionService.mediaChunkAad(messageId, 0, 0, 1);
    final b = await svc.encryptChunk(chunkData(0, 4000), svc.newMediaKey(),
        aad: aad);
    expect(
      () => svc.decryptChunk(b, svc.newMediaKey(), aad: aad),
      throwsA(anything),
    );
  });
}
