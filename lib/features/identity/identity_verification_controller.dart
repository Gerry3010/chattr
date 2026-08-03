// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/kem_key_binding.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chat_member_keys_repository.dart';
import '../profiles/profile_model.dart';
import '../profiles/profiles_controller.dart';
import '../profiles/profiles_repository.dart';
import 'identity_verification_repository.dart';
import 'safety_number.dart';

/// Ceiling for the network fetches behind the verification UI. Without it a
/// half-dead socket after resume left the safety-number spinner turning
/// forever; on timeout the UI falls back to cached data / the info card.
const _verificationFetchTimeout = Duration(seconds: 10);

/// The peer's profile with a FRESH identity key — forced past the session
/// cache (the verification screen must see a key the peer published a minute
/// ago). Falls back to the cached profile when the network is slow/dead.
Future<Profile> _freshProfile(Ref ref, String userId) async {
  final profiles = ref.read(profilesControllerProvider.notifier);
  try {
    return await profiles
        .getProfile(userId, forceRefresh: true)
        .timeout(_verificationFetchTimeout);
  } catch (e) {
    logger.warning(
      'Fresh profile fetch for $userId failed — using cache: $e',
      tag: 'IdentityVerification',
    );
    return profiles.getCachedProfile(userId) ?? Profile.nonExistent(userId);
  }
}

/// Trust state of a peer's identity key for the UI badge/banner (audit C1).
/// Fetches the peer's published identity key, records it (TOFU-pinning a
/// first-seen key), and returns the resulting state — [IdentityVerificationState.changed]
/// when the current key no longer matches what this device pinned.
final peerVerificationProvider = FutureProvider.autoDispose
    .family<IdentityVerificationState, String>((ref, userId) async {
  final profile = await _freshProfile(ref, userId);
  return ref
      .read(identityVerificationRepositoryProvider)
      .recordSeen(userId, profile.identityPublicKey);
});

/// Per-chat verification summary: for every OTHER member with a registered
/// KEM key, the effective trust state combining (a) the identity-key pin
/// ([IdentityVerificationRepository.recordSeen]) and (b) whether the KEM key
/// blob on the server carries a valid signature by that pinned identity
/// ([KemKeyBinding.verify]). A signed-but-invalid blob is the loud case — it
/// means the server (or someone) swapped the key — and surfaces as [IdentityVerificationState.changed].
class ChatVerificationSummary {
  final Map<String, IdentityVerificationState> peers;

  const ChatVerificationSummary(this.peers);

  bool get anyChanged =>
      peers.values.contains(IdentityVerificationState.changed);

  bool get allVerified =>
      peers.isNotEmpty &&
      peers.values.every((s) => s == IdentityVerificationState.verified);

  List<String> get changedPeers => [
        for (final e in peers.entries)
          if (e.value == IdentityVerificationState.changed) e.key,
      ];
}

/// Verifies every co-member's registered KEM key against their pinned
/// identity key (audit C1, warn-only). Drives the shield badge in the chat
/// app bar, the members list and the "safety number changed" banner.
final chatVerificationProvider = FutureProvider.autoDispose
    .family<ChatVerificationSummary, String>((ref, chatId) async {
  final myId = ref.watch(authControllerProvider);
  final memberKeys =
      await ref.read(chatMemberKeysRepositoryProvider).getAllPublicKeys(chatId);
  final pins = ref.read(identityVerificationRepositoryProvider);
  final profiles = ref.read(profilesControllerProvider.notifier);

  final result = <String, IdentityVerificationState>{};
  for (final entry in memberKeys.entries) {
    final userId = entry.key;
    if (userId == myId) continue;

    var state = IdentityVerificationState.unknown;
    try {
      final profile = await profiles.getProfile(userId);
      state = await pins.recordSeen(userId, profile.identityPublicKey);
    } catch (e) {
      logger.warning(
        'Could not resolve identity for $userId in chat $chatId',
        tag: 'ChatVerification',
        error: e,
      );
    }

    // The pinned identity is the anchor; check the KEM key blob against it.
    if (state == IdentityVerificationState.verified ||
        state == IdentityVerificationState.unverified) {
      final anchor = await pins.pinnedKey(userId);
      if (anchor != null) {
        if (KemKeyBinding.signatureOf(entry.value) == null) {
          // Peer has an identity key but this chat key predates signing
          // (older client). Not attributable — degrade to unverified.
          state = IdentityVerificationState.unverified;
        } else if (!await KemKeyBinding.verify(chatId, entry.value, anchor)) {
          state = IdentityVerificationState.changed;
        }
      }
    }
    result[userId] = state;
  }
  return ChatVerificationSummary(result);
});

/// The formatted safety number between the current user and [userId], or null
/// if either side hasn't published an identity key yet. Shown on the
/// verification screen for an out-of-band comparison.
final safetyNumberProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, userId) async {
  final mine = await ref
      .read(identityKeyManagerProvider)
      .publicKeyBase64()
      .timeout(_verificationFetchTimeout, onTimeout: () => null);
  final profile = await _freshProfile(ref, userId);
  final theirs = profile.identityPublicKey;
  if (mine == null || theirs == null || theirs.isEmpty) return null;
  // 5200 SHA-512 iterations — run off the UI isolate.
  return compute(_formatSafetyNumber, [mine, theirs]);
});

String _formatSafetyNumber(List<String> keys) =>
    SafetyNumber.formatted(keys[0], keys[1]);

/// Best-effort self-heal for OUR side of the safety number: make sure the
/// identity key pair exists and its public half is published to `profiles`.
/// Idempotent and cheap. The startup publish (`ChatsController._init`) can be
/// skipped or fail silently (locked keystore, offline, biometric-gate early
/// return) and never retries — watching this from the verification/QR screens
/// heals such a device the moment the user looks at identity UI.
final identityPublishRetryProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final myId = ref.read(authControllerProvider);
  if (myId == null) return false;
  try {
    final pub = await ref
        .read(identityKeyManagerProvider)
        .ensureKeyPair()
        .timeout(_verificationFetchTimeout);
    await ProfilesRepository(ref.read(supabaseClientProvider))
        .publishIdentityKey(userId: myId, identityPublicKey: pub)
        .timeout(_verificationFetchTimeout);
    return true;
  } catch (e) {
    logger.warning(
      'Identity publish retry failed: $e',
      tag: 'IdentityVerification',
    );
    return false;
  }
});
