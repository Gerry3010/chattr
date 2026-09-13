// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt_lib;

import 'encryption_key_manager.dart';
import 'key_locked_exception.dart';

/// Encryption Service
///
/// Provides AES-256-CBC encryption and decryption for local data
class EncryptionService {
  final EncryptionKeyManager _keyManager;

  EncryptionService(this._keyManager);

  /// Encrypt plaintext string
  /// Returns encrypted string in format: "iv:ciphertext" (both base64 encoded)
  Future<String?> encrypt(String plaintext) async {
    try {
      // Get encryption key
      final keyString = await _keyManager.getKey(requireBiometric: false);
      if (keyString == null) {
        return null;
      }

      // Parse key
      final keyBytes = base64.decode(keyString);
      final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));

      // Generate random IV
      final iv = encrypt_lib.IV.fromSecureRandom(16);

      // Create encrypter
      final encrypter = encrypt_lib.Encrypter(
        encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc),
      );

      // Encrypt
      final encrypted = encrypter.encrypt(plaintext, iv: iv);

      // Return format: "iv:ciphertext"
      return '${iv.base64}:${encrypted.base64}';
    } on KeyLockedException {
      // The key is locked (app lock engaged, device not present). This is NOT
      // "encryption failed" — swallowing it to null would silently DROP whatever
      // was being persisted (a message, a receipt). Surface it so the caller
      // defers the write until after unlock.
      rethrow;
    } catch (e) {
      return null;
    }
  }

  /// Decrypt ciphertext string
  /// Expects format: "iv:ciphertext" (both base64 encoded)
  Future<String?> decrypt(String ciphertext) async {
    try {
      // Get encryption key
      final keyString = await _keyManager.getKey(requireBiometric: false);
      if (keyString == null) {
        return null;
      }

      // Parse key
      final keyBytes = base64.decode(keyString);
      final key = encrypt_lib.Key(Uint8List.fromList(keyBytes));

      // Split IV and ciphertext
      final parts = ciphertext.split(':');
      if (parts.length != 2) {
        return null;
      }

      final iv = encrypt_lib.IV.fromBase64(parts[0]);
      final encrypted = encrypt_lib.Encrypted.fromBase64(parts[1]);

      // Create encrypter
      final encrypter = encrypt_lib.Encrypter(
        encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc),
      );

      // Decrypt
      final decrypted = encrypter.decrypt(encrypted, iv: iv);

      return decrypted;
    } on KeyLockedException {
      // The key is locked, not the data corrupt. A null return here reads as
      // "undecryptable": the row can be dropped and the sent-receipt watermark
      // can advance PAST a message that was merely locked. Rethrow so the read
      // path shows the lock screen and retries after unlock — never advancing or
      // dropping anything.
      rethrow;
    } catch (e) {
      return null;
    }
  }

  /// Encrypt JSON object
  Future<String?> encryptJson(Map<String, dynamic> json) async {
    final jsonString = jsonEncode(json);
    return await encrypt(jsonString);
  }

  /// Decrypt to JSON object
  Future<Map<String, dynamic>?> decryptJson(String ciphertext) async {
    final decrypted = await decrypt(ciphertext);
    if (decrypted == null) {
      return null;
    }
    
    try {
      return jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}
