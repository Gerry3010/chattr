// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-12: a new 1:1 between web and Android showed six "neue Schlüssel"
// notices within 100 ms of its creation, and Android could not open messages
// addressed to it. Several paths a new chat sets off each saw "no key yet"
// and generated their own; the key kept locally and the key published last
// could differ. These tests pin the guard: at most one generation per chat,
// an existing key is never replaced by a plain generate, and rotation still
// keeps the old one.
// Requires the native lib — run `./native/build.sh` first; skips otherwise.

import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/ml_kem_ffi.dart'
    show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('gleichzeitige Aufrufe erzeugen genau einen Schlüssel', () async {
    if (!libExists) return markTestSkipped('native lib not built');
    const storage = FlutterSecureStorage();
    // Two instances, as different parts of the app may hold, same storage.
    final a = ChatKeyPairManager(storage);
    final b = ChatKeyPairManager(storage);

    final pubs = await Future.wait([
      a.generateKeyPairForChat('chat').then((_) => a.getPublicKey('chat')),
      b.generateKeyPairForChat('chat').then((_) => b.getPublicKey('chat')),
      a.generateKeyPairForChat('chat').then((_) => a.getPublicKey('chat')),
    ]);
    expect(pubs.toSet(), hasLength(1),
        reason: 'every concurrent caller must see and publish the same key');
    expect(await a.getAllPrivateKeys('chat'), hasLength(1),
        reason: 'no hidden second generation');
  });

  test('ein vorhandener Schlüssel wird nicht ersetzt', () async {
    if (!libExists) return markTestSkipped('native lib not built');
    final m = ChatKeyPairManager(const FlutterSecureStorage());
    await m.generateKeyPairForChat('chat');
    final first = await m.getPublicKey('chat');
    await m.generateKeyPairForChat('chat');
    expect(await m.getPublicKey('chat'), first);
  });

  test('Rotation erzeugt weiter einen neuen und behält den alten', () async {
    if (!libExists) return markTestSkipped('native lib not built');
    final m = ChatKeyPairManager(const FlutterSecureStorage());
    await m.generateKeyPairForChat('chat');
    final before = await m.getPrivateKey('chat');
    final rotated = await m.rotateKeyPairForChat('chat');
    expect(rotated, isNot(await Future.value(null)));
    expect(await m.getPrivateKey('chat'), isNot(before));
    expect(await m.getAllPrivateKeys('chat'), [await m.getPrivateKey('chat'), before]);
  });

  test('Rotation während der ersten Erzeugung landet nicht darunter', () async {
    if (!libExists) return markTestSkipped('native lib not built');
    final m = ChatKeyPairManager(const FlutterSecureStorage());
    final first = m.generateKeyPairForChat('chat');
    final rotated = await m.rotateKeyPairForChat('chat');
    await first;
    expect(await m.getPublicKey('chat'), rotated,
        reason: 'the rotation must be the current key afterwards');
    expect(await m.getAllPrivateKeys('chat'), hasLength(2));
  });
}
