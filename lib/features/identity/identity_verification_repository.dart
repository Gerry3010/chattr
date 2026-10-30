// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// Stores which identity key this device has pinned for a peer, and whether it
/// was explicitly verified. TOFU (trust-on-first-use): the first key we see for
/// a peer is pinned automatically as [IdentityVerificationState.unverified];
/// scanning their QR upgrades it to [verified]; a later mismatch surfaces as
/// [changed] until the user acknowledges it.
///
/// **The person is the identity key — the user id is only an address.**
/// Until 2026-08 this store was keyed by user id (`identity_pins_v1`:
/// `userId → {k, v}`), which quietly asserted that one account = one person
/// forever. Two things broke on that assumption:
///
///  * Verifying somebody in a group and then opening a 1:1 with them is the
///    same person twice. Keyed by id that happens to work today only because
///    the id is stable; nothing about it was ever *about* the person.
///  * Any later attempt to give a user chat-local addresses (the per-chat-id
///    idea, 2026-08-24) would have shown the same verified contact as an
///    unverified stranger in every other chat.
///
/// So the document holds two maps: [_keys] is the person (identity key →
/// verified flag), [_aliases] maps every address we have seen that person under
/// onto their key. Verifying once now counts everywhere that person appears —
/// which is the behaviour a user already expects.
///
/// Pins are public keys (not secret), but they live in secure storage as one
/// JSON document so no local-DB schema migration is needed and they survive
/// alongside the other key material.
class IdentityVerificationRepository {
  /// Same document shape as [unlockedStorageKey]; only the iOS keychain class
  /// differs (see [iOptions]).
  @visibleForTesting
  static const String storageKey = 'identity_pins_v3';

  /// The document until 2026-10-24, stored under the plugin's default iOS
  /// class `unlocked`. Read once to move it over, and kept afterwards for the
  /// same reason as [legacyStorageKey].
  @visibleForTesting
  static const String unlockedStorageKey = 'identity_pins_v2';

  /// The pre-2026-08 document (`userId → {k, v}`), read once for the upgrade.
  /// Deliberately NOT deleted afterwards: it is a few hundred bytes, and
  /// keeping it means a rollback to an older build still finds its pins
  /// instead of asking the user to re-verify everyone.
  @visibleForTesting
  static const String legacyStorageKey = 'identity_pins_v1';

  /// iOS keychain class for [storageKey]: readable from the first unlock after
  /// boot on, also while the phone is locked again.
  ///
  /// A call answered on the lock screen signs and verifies against these pins
  /// while the phone stays locked. Under the plugin default (`unlocked`) that
  /// read failed with -25308 and the call died right after "accept" — the
  /// caller saw "call failed" (Gerry, 2026-10-24). Not `_this_device`: pins
  /// are public keys, and only WHEN they are readable changes here, not
  /// whether a backup carries them.
  ///
  /// A new key name rather than new options on the old one: the plugin puts
  /// the class into the READ query as well, so the old item would no longer be
  /// found, and every pin would quietly start over as unverified.
  @visibleForTesting
  static const IOSOptions iOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  /// identity key (base64) → `{'v': verified}`
  static const String _keys = 'keys';

  /// peer user id → identity key (base64)
  static const String _aliases = 'aliases';

  final FlutterSecureStorage _storage;

  IdentityVerificationRepository(this._storage);

  Future<Map<String, dynamic>> _load() async {
    final doc = _parse(
      await _storage.read(key: storageKey, iOptions: iOptions),
    );
    if (doc != null) return doc;
    return _migrate();
  }

  /// The document in [raw], or null when there is none or it is corrupt — a
  /// corrupt one falls through to the older stores rather than silently
  /// starting empty, the old pins may still be there.
  static Map<String, dynamic>? _parse(String? raw) {
    if (raw == null) return null;
    try {
      final doc = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return {
        _keys: Map<String, dynamic>.from(doc[_keys] as Map? ?? {}),
        _aliases: Map<String, dynamic>.from(doc[_aliases] as Map? ?? {}),
      };
    } catch (_) {
      return null;
    }
  }

  /// Fills [storageKey] from the newest older store there is. Neither old
  /// entry is deleted.
  ///
  /// Both reads go through the default class, so on a phone that is locked
  /// before this ever ran they THROW (-25308) — on purpose. An unreadable
  /// store must never pass for an empty one: that would write an empty
  /// document over the pins and every verified contact would come back
  /// unverified. The move happens on the next read with the phone unlocked.
  Future<Map<String, dynamic>> _migrate() async {
    final doc =
        _parse(await _storage.read(key: unlockedStorageKey)) ??
        await _foldLegacy();
    await _save(doc);
    return doc;
  }

  /// Reads `identity_pins_v1` and folds it into the new shape. Two ids that
  /// pinned the SAME key collapse onto one person, and that person counts as
  /// verified if either of the old entries was.
  Future<Map<String, dynamic>> _foldLegacy() async {
    final keys = <String, dynamic>{};
    final aliases = <String, dynamic>{};

    final raw = await _storage.read(key: legacyStorageKey);
    if (raw != null) {
      try {
        final old = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        old.forEach((userId, entry) {
          if (entry is! Map || entry['k'] is! String) return;
          final key = entry['k'] as String;
          aliases[userId] = key;
          final wasVerified = entry['v'] == true;
          final known = keys[key];
          keys[key] = {
            'v': wasVerified || (known is Map && known['v'] == true),
          };
        });
      } catch (_) {
        // Unreadable legacy document — start clean. Peers re-pin on next sight
        // as unverified, which is the safe direction (a badge appears, nothing
        // is silently trusted).
      }
    }

    return {_keys: keys, _aliases: aliases};
  }

  Future<void> _save(Map<String, dynamic> doc) => _storage.write(
    key: storageKey,
    value: jsonEncode(doc),
    iOptions: iOptions,
  );

  /// The whole pin document as JSON, for the backup (CHAT-8). Pins are public
  /// keys; what a backup saves here is which contacts were verified.
  Future<String> exportDocument() async => jsonEncode(await _load());

  /// Folds a backed-up pin document into this device's (CHAT-8). This
  /// device's own aliases win (it has seen those peers more recently); a key
  /// counts as verified if either side verified it. A document that does not
  /// parse is ignored, never written over the existing pins.
  Future<void> importDocument(String raw) async {
    final restored = _parse(raw);
    if (restored == null) return;
    await _save(mergePinDocuments(await _load(), restored));
  }

  /// The merge rule of [importDocument], pure for the test.
  @visibleForTesting
  static Map<String, dynamic> mergePinDocuments(
    Map<String, dynamic> local,
    Map<String, dynamic> restored,
  ) {
    final keys = Map<String, dynamic>.from(restored[_keys] as Map);
    Map<String, dynamic>.from(local[_keys] as Map).forEach((key, entry) {
      final verified = (entry is Map && entry['v'] == true) ||
          _isVerifiedKey(restored, key);
      keys[key] = {'v': verified};
    });
    final aliases = Map<String, dynamic>.from(restored[_aliases] as Map)
      ..addAll(Map<String, dynamic>.from(local[_aliases] as Map));
    return {_keys: keys, _aliases: aliases};
  }

  /// The identity key this device has pinned for [userId], or null.
  Future<String?> pinnedKey(String userId) async {
    final doc = await _load();
    final key = (doc[_aliases] as Map)[userId];
    return key is String ? key : null;
  }

  /// Whether the person behind [userId] was explicitly verified.
  Future<bool> isVerified(String userId) async {
    final doc = await _load();
    final key = (doc[_aliases] as Map)[userId];
    if (key is! String) return false;
    return _isVerifiedKey(doc, key);
  }

  static bool _isVerifiedKey(Map<String, dynamic> doc, String key) {
    final entry = (doc[_keys] as Map)[key];
    return entry is Map && entry['v'] == true;
  }

  /// Record the peer's [currentKey] (from their profile) and return the
  /// resulting trust state. TOFU-pins a first-seen key as unverified; never
  /// silently overwrites a differing pin (that surfaces as [changed] so the
  /// user can decide).
  ///
  /// A first-seen *address* whose key we already verified under another address
  /// comes back [verified] straight away — same person, already checked.
  Future<IdentityVerificationState> recordSeen(
    String userId,
    String? currentKey,
  ) async {
    if (currentKey == null || currentKey.isEmpty) {
      return IdentityVerificationState.unknown;
    }
    final doc = await _load();
    final aliases = doc[_aliases] as Map;
    final keys = doc[_keys] as Map;
    final pinned = aliases[userId];

    if (pinned is! String) {
      aliases[userId] = currentKey;
      keys[currentKey] ??= {'v': false};
      await _save(doc);
      return _isVerifiedKey(doc, currentKey)
          ? IdentityVerificationState.verified
          : IdentityVerificationState.unverified;
    }

    if (pinned == currentKey) {
      return _isVerifiedKey(doc, currentKey)
          ? IdentityVerificationState.verified
          : IdentityVerificationState.unverified;
    }
    return IdentityVerificationState.changed;
  }

  /// Explicitly pin [key] for [userId]. Used when scanning a QR ([verified] =
  /// true) or when the user acknowledges a key change (accept new key; pass
  /// whether they verified it in person).
  ///
  /// Verification attaches to the KEY, so confirming a safety number here also
  /// clears the badge for the same person in every other chat.
  Future<void> pin(
    String userId,
    String key, {
    required bool verified,
  }) async {
    final doc = await _load();
    final aliases = doc[_aliases] as Map;
    final keys = doc[_keys] as Map;

    final previous = aliases[userId];
    aliases[userId] = key;
    final known = keys[key];
    keys[key] = {'v': verified || (known is Map && known['v'] == true)};

    if (previous is String && previous != key) _dropIfOrphaned(doc, previous);
    await _save(doc);
  }

  /// Forget a peer's pin (e.g. account wipe).
  Future<void> forget(String userId) async {
    final doc = await _load();
    final key = (doc[_aliases] as Map).remove(userId);
    if (key is String) _dropIfOrphaned(doc, key);
    await _save(doc);
  }

  /// Drop a key nobody addresses any more — otherwise a forgotten peer would
  /// leave their verified flag behind, and a later address reusing that key
  /// would come back "verified" on the strength of a decision the user has
  /// since revoked.
  static void _dropIfOrphaned(Map<String, dynamic> doc, String key) {
    final stillUsed = (doc[_aliases] as Map).values.contains(key);
    if (!stillUsed) (doc[_keys] as Map).remove(key);
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
