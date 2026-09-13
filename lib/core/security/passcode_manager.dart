// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-lock passcode, stored as a salted PBKDF2-HMAC-SHA256 hash in secure
/// storage. The passcode is the fallback unlock for devices without
/// biometrics (and an additional option everywhere else) — it never leaves
/// the device and is never stored in plaintext.
class PasscodeManager {
  static const String _hashKey = 'app_lock_passcode_hash_v1';
  static const String _saltKey = 'app_lock_passcode_salt_v1';
  static const int _iterations = 30000;

  final FlutterSecureStorage _storage;

  PasscodeManager(this._storage);

  Future<bool> hasPasscode() async =>
      (await _storage.read(key: _hashKey)) != null;

  Future<void> setPasscode(String passcode) async {
    final salt = _randomSalt();
    final hash = _derive(passcode, salt);
    await _storage.write(key: _saltKey, value: base64.encode(salt));
    await _storage.write(key: _hashKey, value: base64.encode(hash));
  }

  Future<bool> verifyPasscode(String passcode) async {
    final saltB64 = await _storage.read(key: _saltKey);
    final hashB64 = await _storage.read(key: _hashKey);
    if (saltB64 == null || hashB64 == null) return false;
    final derived = _derive(passcode, base64.decode(saltB64));
    return _constantTimeEquals(derived, base64.decode(hashB64));
  }

  Future<void> removePasscode() async {
    await _storage.delete(key: _hashKey);
    await _storage.delete(key: _saltKey);
  }

  static List<int> _randomSalt() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256));
  }

  /// PBKDF2-HMAC-SHA256 (single 32-byte block is enough for a passcode hash).
  static Uint8List _derive(String passcode, List<int> salt) {
    final hmac = Hmac(sha256, utf8.encode(passcode));
    // Block index 1, big-endian, per RFC 2898.
    var u = Uint8List.fromList(hmac.convert([...salt, 0, 0, 0, 1]).bytes);
    final result = Uint8List.fromList(u);
    for (var i = 1; i < _iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return result;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
