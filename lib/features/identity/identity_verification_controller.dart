// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/kem_key_binding.dart';
import '../../core/security/key_locked_exception.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chat_member_keys_repository.dart';
import '../profiles/profile_model.dart';
import '../profiles/profiles_controller.dart';
import 'installation_status.dart';
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

/// A safety number as shown, with the peer key it was computed from. "Mark
/// as verified" pins exactly [peerKey] (CHAT-42): pinning whatever the profile
/// says at the moment of the tap could pin a key the user never compared.
typedef ShownSafetyNumber = ({String number, String peerKey});

/// The formatted safety number between the current user and [userId], or null
/// if either side hasn't published an identity key yet. Shown on the
/// verification screen for an out-of-band comparison.
final safetyNumberProvider = FutureProvider.autoDispose
    .family<ShownSafetyNumber?, String>((ref, userId) async {
  // A locked own key must NOT propagate as an error here.
  //
  // This screen's error branch renders a raw exception and nothing else, so an
  // IdentityKeyLockedException took the whole card down — including
  // `_unknownInfo`, which is where the "create a new key" button lives. The
  // escape hatch was therefore unreachable in precisely the state it exists
  // for: identity present but unreadable, messages going out unsigned, and the
  // user looking at `Error: IdentityKeyLockedException: …` with no way out.
  // (Shipped in 1.14.0, found on a real device 2026-08-07.)
  //
  // Treating it as "no number available" hands the case to `_unknownInfo`,
  // which reads the SAME exception off myIdentityPublicKeyProvider and offers
  // the remedy. Only the locked case is swallowed — anything else still
  // surfaces, because an unexpected failure should not look like "not
  // published yet".
  String? mine;
  try {
    mine = await ref
        .read(identityKeyManagerProvider)
        .publicKeyBase64()
        .timeout(_verificationFetchTimeout, onTimeout: () => null);
  } on IdentityKeyLockedException {
    return null;
  }
  final profile = await _freshProfile(ref, userId);
  final theirs = profile.identityPublicKey;
  if (mine == null || theirs == null || theirs.isEmpty) return null;
  // 5200 SHA-512 iterations — run off the UI isolate.
  final number = await compute(_formatSafetyNumber, [mine, theirs]);
  return (number: number, peerKey: theirs);
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
    // A replaced installation must not push its old key back over the one
    // the account now lives with on another device.
    if (await ref.read(installationStatusProvider(myId).future) ==
        InstallationStatus.superseded) {
      return false;
    }
    final identity = ref.read(identityKeyManagerProvider);
    final pub = await identity.ensureKeyPair().timeout(_verificationFetchTimeout);
    await ProfilesRepository(ref.read(supabaseClientProvider))
        .publishIdentityKey(userId: myId, identityPublicKey: pub)
        .timeout(_verificationFetchTimeout);
    await identity.markPublished(pub);
    return true;
  } catch (e) {
    logger.warning(
      'Identity publish retry failed: $e',
      tag: 'IdentityVerification',
    );
    return false;
  }
});

/// What the "no safety number yet" card should offer for OUR side.
enum IdentityRemedy {
  /// Our key is fine — the gap is on the peer's side, nothing for us to do.
  none,

  /// We have (or can mint) a key, it just isn't published yet. Retrying is
  /// enough and costs nothing.
  publish,

  /// The seed is GONE while a key provably existed. `ensureKeyPair()` throws
  /// forever by design, so publishing can only fail — the only way out is an
  /// explicit, confirmed re-mint.
  regenerate,
}

/// Decides which remedy to offer, kept out of the widget so the choice can be
/// tested without building a screen. Offering "publish" in the lost case is
/// what made the old UI a dead end that looked like a remedy; offering
/// "regenerate" when the key is merely unpublished would flip every peer's
/// safety number for no reason. Both mistakes are one `if` apart.
IdentityRemedy identityRemedyFor(Object? myKeyError) {
  if (myKeyError == null) return IdentityRemedy.none;
  return myKeyError is IdentityKeyLockedException
      ? IdentityRemedy.regenerate
      : IdentityRemedy.publish;
}

/// The way OUT of a lost identity.
///
/// The anti-wipe hardening in [IdentityKeyManager] deliberately refuses to
/// re-mint when the seed is gone but a key provably existed — a silent re-mint
/// flips every peer's safety number with no explanation, which is exactly the
/// failure it was built to stop. The consequence, though, is that such a device
/// is stuck: [identityPublishRetryProvider] calls `ensureKeyPair()`, which
/// throws [IdentityKeyLockedException] forever, so the "publish now" button
/// fails every time and the user's messages keep going out unsigned.
///
/// This is the deliberate escape hatch. It is a plain service and NOT a
/// FutureProvider on purpose: a provider could be `watch`ed by accident, and
/// anything that re-mints an identity key must only ever run because a human
/// pressed a button and confirmed the consequence.
class IdentityRecovery {
  final Ref _ref;

  IdentityRecovery(this._ref);

  /// Mint a brand-new identity key and publish its public half. Returns false
  /// (and logs) instead of throwing, so the caller can just show a message.
  ///
  /// Peers will see "safety number changed" and must re-verify — the caller is
  /// responsible for having said so BEFORE calling this.
  Future<bool> regenerateAndPublish() async {
    final myId = _ref.read(authControllerProvider);
    if (myId == null) return false;
    try {
      final identity = _ref.read(identityKeyManagerProvider);
      final pub = await identity.regenerate().timeout(_verificationFetchTimeout);
      await ProfilesRepository(_ref.read(supabaseClientProvider))
          .publishIdentityKey(userId: myId, identityPublicKey: pub)
          .timeout(_verificationFetchTimeout);
      // A deliberate regenerate is a deliberate takeover: from now on THIS
      // installation is the current one again.
      await identity.markPublished(pub);
      _ref.invalidate(installationStatusProvider(myId));
      logger.info(
        'Identity key regenerated on user request and republished',
        tag: 'IdentityVerification',
      );
      return true;
    } catch (e) {
      logger.warning(
        'Identity regenerate failed: $e',
        tag: 'IdentityVerification',
      );
      return false;
    }
  }
}

final identityRecoveryProvider = Provider<IdentityRecovery>(
  (ref) => IdentityRecovery(ref),
);
