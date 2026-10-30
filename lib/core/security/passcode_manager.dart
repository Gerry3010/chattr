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

  /// Wrong guesses in a row, and until when the next guess is refused
  /// (CHAT-37). A four-digit passcode with unlimited guesses falls to anyone
  /// who holds the unlocked phone for an afternoon.
  static const String _failuresKey = 'app_lock_passcode_failures_v1';
  static const String _lockedUntilKey = 'app_lock_passcode_locked_until_v1';

  /// Free guesses before the first wait.
  static const int freeAttempts = 5;

  /// The wait after [failures] wrong guesses in a row: none for the first
  /// [freeAttempts], then 30 s, doubling with every further miss, at most an
  /// hour.
  static Duration lockoutAfter(int failures) {
    if (failures < freeAttempts) return Duration.zero;
    final steps = min(failures - freeAttempts, 7);
    return Duration(seconds: min(3600, 30 << steps));
  }

  /// How long the next guess still has to wait; zero if it may go now.
  Future<Duration> lockoutRemaining([DateTime? now]) async {
    final raw = await _storage.read(key: _lockedUntilKey);
    final until = raw == null ? null : DateTime.tryParse(raw);
    if (until == null) return Duration.zero;
    final left = until.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Future<bool> verifyPasscode(String passcode, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (await lockoutRemaining(at) > Duration.zero) return false;
    final saltB64 = await _storage.read(key: _saltKey);
    final hashB64 = await _storage.read(key: _hashKey);
    if (saltB64 == null || hashB64 == null) return false;
    final derived = _derive(passcode, base64.decode(saltB64));
    final ok = _constantTimeEquals(derived, base64.decode(hashB64));
    if (ok) {
      await _clearFailures();
    } else {
      final failures =
          (int.tryParse(await _storage.read(key: _failuresKey) ?? '') ?? 0) +
              1;
      await _storage.write(key: _failuresKey, value: '$failures');
      final wait = lockoutAfter(failures);
      if (wait > Duration.zero) {
        await _storage.write(
          key: _lockedUntilKey,
          value: at.add(wait).toUtc().toIso8601String(),
        );
      }
    }
    return ok;
  }

  Future<void> _clearFailures() async {
    await _storage.delete(key: _failuresKey);
    await _storage.delete(key: _lockedUntilKey);
  }

  Future<void> removePasscode() async {
    await _storage.delete(key: _hashKey);
    await _storage.delete(key: _saltKey);
    await _clearFailures();
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
