// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Unit tests for the backup crypto envelope (BackupCrypto): seal -> open round
// trips the payload; a wrong passphrase, a tampered file, and a non-Chattr file
// all fail cleanly with BackupException rather than returning garbage. The
// device-side gather/restore (BackupService) is exercised manually (needs secure
// storage + a live Supabase session); the crypto is the part worth locking here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/backup/backup_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';

void main() {
  BackupPayload samplePayload() => const BackupPayload(
        userId: '4f6dbce8-453f-47bf-b625-4868be77388f',
        refreshToken: 'refresh-token-abc123',
        encryptionKey: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
        chatKeys: {
          'chat_pqc_key_chat-1': '{"xPriv":"a","xPub":"b","mPriv":"c","mPub":"d"}',
          'chat_pqc_key_prev_chat-1': '{"xPriv":"e","xPub":"f","mPriv":"g","mPub":"h"}',
          'chat_pqc_key_chat-2': '{"xPriv":"i","xPub":"j","mPriv":"k","mPub":"l"}',
        },
      );

  test('seal -> open round-trips every field', () async {
    final payload = samplePayload();
    final bytes = await BackupCrypto.seal(payload, 'correct horse battery staple');
    final out = await BackupCrypto.open(bytes, 'correct horse battery staple');

    expect(out.userId, payload.userId);
    expect(out.refreshToken, payload.refreshToken);
    expect(out.encryptionKey, payload.encryptionKey);
    expect(out.chatKeys, payload.chatKeys);
  });

  test('wrong passphrase fails with BackupException (not garbage)', () async {
    final bytes = await BackupCrypto.seal(samplePayload(), 'the right one');
    await expectLater(
      BackupCrypto.open(bytes, 'the WRONG one'),
      throwsA(isA<BackupException>()),
    );
  });

  test('a random / non-Chattr file is rejected', () async {
    final notABackup = Uint8List.fromList(utf8.encode('{"hello":"world"}'));
    await expectLater(
      BackupCrypto.open(notABackup, 'whatever'),
      throwsA(isA<BackupException>()),
    );
    final garbage = Uint8List.fromList([0, 1, 2, 3, 255, 254]);
    await expectLater(
      BackupCrypto.open(garbage, 'whatever'),
      throwsA(isA<BackupException>()),
    );
  });

  test('a tampered ciphertext fails authentication', () async {
    final bytes = await BackupCrypto.seal(samplePayload(), 'pass');
    final env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    // Flip a byte in the ciphertext.
    final ct = base64.decode(env['ct'] as String);
    ct[0] ^= 0xFF;
    env['ct'] = base64.encode(ct);
    final tampered = Uint8List.fromList(utf8.encode(jsonEncode(env)));
    await expectLater(
      BackupCrypto.open(tampered, 'pass'),
      throwsA(isA<BackupException>()),
    );
  });

  test('each backup uses a fresh salt + nonce (no reuse)', () async {
    final payload = samplePayload();
    final a = jsonDecode(utf8.decode(await BackupCrypto.seal(payload, 'p'))) as Map<String, dynamic>;
    final b = jsonDecode(utf8.decode(await BackupCrypto.seal(payload, 'p'))) as Map<String, dynamic>;
    expect(a['salt'], isNot(b['salt']));
    expect(a['nonce'], isNot(b['nonce']));
    expect(a['ct'], isNot(b['ct']));
  });

  // Restore must write chat keys through ChatKeyPairManager's hardened path
  // (audit M5 device-binding), NOT raw to secure storage. This locks the routing:
  // a key restored under its backup storage key (chat_pqc_key_*, incl. the
  // retained _prev_ generation) is read back by the normal decrypt path with no
  // key-format / namespace mismatch. (The hardening ATTRIBUTES themselves —
  // accessibility/accountName — are only observable on a real device keychain;
  // the mock ignores options, so this proves routing/format, not the ACL.)
  group('restore writes chat keys through the hardened read/write path', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

    test('importRestoredKey lands where the decrypt path reads', () async {
      final mgr = ChatKeyPairManager(const FlutterSecureStorage());
      final restored = samplePayload().chatKeys; // chat_pqc_key_* → raw record
      for (final e in restored.entries) {
        await mgr.importRestoredKey(e.key, e.value);
      }

      // Read each stored key only ONCE: the in-memory secure-storage mock can't
      // namespace hardened vs legacy by accountName, so _readMigrating's one-shot
      // legacy sweep drops a key on a second read (a real keychain isolates the
      // two, so this is a mock artifact, not a bug).
      //
      // chat-1: current + the retained previous generation both restore and are
      // returned by the decrypt path, in order.
      expect(
        await mgr.getAllPrivateKeys('chat-1'),
        <String>[
          jsonEncode(<String, String>{'x': 'a', 'm': 'c'}),
          jsonEncode(<String, String>{'x': 'e', 'm': 'g'}),
        ],
      );
      // chat-2 (an independent key) also restores + reads back.
      expect(await mgr.getPrivateKey('chat-2'),
          jsonEncode(<String, String>{'x': 'i', 'm': 'k'}));
    });
  });
}
