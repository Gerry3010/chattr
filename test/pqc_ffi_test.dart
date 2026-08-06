// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Native (dart:ffi) roundtrip for the hybrid X25519 + ML-KEM-768 KEM via the
// vendored Go c-shared library. X25519 keys come from the cross-platform
// `cryptography` package (same approach used on web); ML-KEM keys and the
// hybrid wrap/unwrap come from the native lib. Skips when the .so is not built
// (run `./native/build.sh` first).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/ml_kem.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart' show mlKemLibraryPathOverride;

void main() {
  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
  });

  Uint8List randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }

  Future<(Uint8List priv, Uint8List pub)> genX25519() async {
    final kp = await X25519().newKeyPair();
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return (priv, pub);
  }

  test('hybrid KEM encrypt -> decrypt round-trips via FFI', () async {
    final (mlkemPriv, mlkemPub) = await mlKemGenerate();
    final (privX, pubX) = await genX25519();

    // ML-KEM-768 key sizes (FIPS 203).
    expect(mlkemPub.length, 1184);
    expect(mlkemPriv.length, 2400);

    final dataKey = randomBytes(32);
    final enc = await mlKemEncryptDataKey(dataKey, pubX, mlkemPub);

    // Hybrid wire format includes the 1088-byte ML-KEM ciphertext.
    expect(enc.length, greaterThanOrEqualTo(32 + 1088));

    final dec = await mlKemDecryptDataKey(enc, privX, mlkemPriv);
    expect(dec, equals(dataKey));
  }, skip: libExists ? false : 'native lib not built ($libPath)');

  test('tampered ciphertext is rejected', () async {
    final (mlkemPriv, mlkemPub) = await mlKemGenerate();
    final (privX, pubX) = await genX25519();
    final dataKey = randomBytes(32);
    final enc = await mlKemEncryptDataKey(dataKey, pubX, mlkemPub);
    enc[enc.length - 1] ^= 0xff;
    expect(
      () => mlKemDecryptDataKey(enc, privX, mlkemPriv),
      throwsA(isA<Object>()),
    );
  }, skip: libExists ? false : 'native lib not built ($libPath)');

  test('X25519-only fallback round-trips (empty ML-KEM key)', () async {
    final (privX, pubX) = await genX25519();
    final dataKey = randomBytes(32);
    // Empty recipient ML-KEM key -> legacy X25519-only wire format.
    final enc = await mlKemEncryptDataKey(dataKey, pubX, Uint8List(0));
    expect(enc.length, lessThan(32 + 1088));
    final dec = await mlKemDecryptDataKey(enc, privX, Uint8List(0));
    expect(dec, equals(dataKey));
  }, skip: libExists ? false : 'native lib not built ($libPath)');
}
