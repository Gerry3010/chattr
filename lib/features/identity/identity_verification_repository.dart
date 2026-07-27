// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// Trust state of a peer's long-term identity key, relative to what this device
/// has pinned (audit P0-a, C1). Enforcement is warn-only: none of these states
/// blocks sending — they drive a badge / banner.
enum IdentityVerificationState {
  /// The peer has not published an identity key yet (older client). No anchor.
  unknown,

  /// First-seen key, accepted on trust (TOFU) but not verified via QR /
  /// safety-number comparison.
  unverified,

  /// The user explicitly verified this key (scanned the peer's QR or confirmed
  /// the safety number).
  verified,

  /// The peer's current key differs from the one this device pinned — a
  /// possible MITM / key-swap, or a legitimate reinstall/recovery. Warn loudly.
  changed,
}

/// Stores, per peer user-id, the identity public key this device has pinned and
/// whether it was explicitly verified. TOFU (trust-on-first-use): the first key
/// we see for a peer is pinned automatically as [IdentityVerificationState.unverified];
/// scanning their QR upgrades it to [verified]; a later mismatch surfaces as
/// [changed] until the user acknowledges it.
///
/// Pins are public keys (not secret), but they live in secure storage as one
/// JSON map so no local-DB schema migration is needed and they survive
/// alongside the other key material.
class IdentityVerificationRepository {
  static const String _storageKey = 'identity_pins_v1';

  final FlutterSecureStorage _storage;

  IdentityVerificationRepository(this._storage);

  Future<Map<String, dynamic>> _load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return <String, dynamic>{};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _save(Map<String, dynamic> map) =>
      _storage.write(key: _storageKey, value: jsonEncode(map));

  /// The identity key this device has pinned for [userId], or null.
  Future<String?> pinnedKey(String userId) async {
    final entry = (await _load())[userId];
    if (entry is Map && entry['k'] is String) return entry['k'] as String;
    return null;
  }

  /// Whether [userId]'s pinned key was explicitly verified.
  Future<bool> isVerified(String userId) async {
    final entry = (await _load())[userId];
    return entry is Map && entry['v'] == true;
  }

  /// Record the peer's [currentKey] (from their profile) and return the
  /// resulting trust state. TOFU-pins a first-seen key as unverified; never
  /// silently overwrites a differing pin (that surfaces as [changed] so the
  /// user can decide).
  Future<IdentityVerificationState> recordSeen(
    String userId,
    String? currentKey,
  ) async {
    if (currentKey == null || currentKey.isEmpty) {
      return IdentityVerificationState.unknown;
    }
    final map = await _load();
    final entry = map[userId];
    if (entry is! Map || entry['k'] is! String) {
      map[userId] = {'k': currentKey, 'v': false};
      await _save(map);
      return IdentityVerificationState.unverified;
    }
    final pinned = entry['k'] as String;
    if (pinned == currentKey) {
      return entry['v'] == true
          ? IdentityVerificationState.verified
          : IdentityVerificationState.unverified;
    }
    return IdentityVerificationState.changed;
  }

  /// Explicitly pin [key] for [userId]. Used when scanning a QR ([verified] =
  /// true) or when the user acknowledges a key change (accept new key; pass
  /// whether they verified it in person).
  Future<void> pin(
    String userId,
    String key, {
    required bool verified,
  }) async {
    final map = await _load();
    map[userId] = {'k': key, 'v': verified};
    await _save(map);
  }

  /// Forget a peer's pin (e.g. account wipe).
  Future<void> forget(String userId) async {
    final map = await _load();
    map.remove(userId);
    await _save(map);
  }
}

final identityVerificationRepositoryProvider =
    Provider<IdentityVerificationRepository>((ref) {
  return IdentityVerificationRepository(ref.read(secureStorageProvider));
});

/// This device's own long-term identity public key (base64), generated on
/// first read. Watched by the QR screen so the code carries `ik` for pinning.
final myIdentityPublicKeyProvider = FutureProvider<String>((ref) async {
  return ref.read(identityKeyManagerProvider).ensureKeyPair();
});
