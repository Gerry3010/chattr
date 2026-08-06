// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/ed25519.dart';
import '../../core/crypto/message_context.dart';
import '../../core/logging/logger_service.dart';
import '../profiles/profiles_controller.dart';
import 'identity_verification_repository.dart';

/// Values stored in `Message.sigStatus` (audit H1, warn-only).
class MessageSigStatus {
  /// Signature present and valid under the sender's (pinned) identity key.
  static const String valid = 'valid';

  /// Signature present but WRONG — possible forgery/injection. The UI marks
  /// the message; it is never dropped (warn-only).
  static const String invalid = 'invalid';

  /// No signature at all, in an envelope version that is supposed to carry one
  /// (v4+). The sender could not sign — typically a device whose identity seed
  /// was lost, where the anti-wipe hardening correctly refuses to silently
  /// re-mint (see IdentityKeyManager). Authorship is unproven, so the UI says
  /// so instead of letting it pass as if it had been checked.
  static const String unsigned = 'unsigned';

  MessageSigStatus._();
}

/// The first envelope version that carries an identity signature. Below this,
/// an absent signature is legacy, not a gap — marking those would light up
/// every pre-v4 message in the history for nothing.
const int _firstSignedEnvelopeVersion = 4;

/// Verifies a decrypted message's identity signature against the sender's
/// pinned identity key (TOFU via the peer's profile when nothing is pinned
/// yet). Returns:
///   • [MessageSigStatus.valid] / [MessageSigStatus.invalid] when a signature
///     was present and could be checked,
///   • [MessageSigStatus.unsigned] when a v4+ envelope carried no signature —
///     the case that used to pass silently,
///   • null when there is genuinely nothing to check (a legacy v3 message, or
///     the sender has no published identity key to check against).
class MessageSignatureVerifier {
  final Ref _ref;

  MessageSignatureVerifier(this._ref);

  Future<String?> verify({
    required MessageContext context,
    required String plaintext,
    required String? signatureB64,
    required int envelopeVersion,
  }) async {
    if (signatureB64 == null || signatureB64.isEmpty) {
      // A v4/v5 envelope without a signature is not "nothing to check" — it is
      // an unproven author. Saying nothing here is what let a device with a
      // lost identity seed send unmarked messages for weeks.
      return envelopeVersion >= _firstSignedEnvelopeVersion
          ? MessageSigStatus.unsigned
          : null;
    }
    try {
      final pins = _ref.read(identityVerificationRepositoryProvider);
      var anchor = await pins.pinnedKey(context.senderId);
      if (anchor == null) {
        // Nothing pinned yet — TOFU the sender's published identity key.
        final profile = await _ref
            .read(profilesControllerProvider.notifier)
            .getProfile(context.senderId);
        await pins.recordSeen(context.senderId, profile.identityPublicKey);
        anchor = profile.identityPublicKey;
      }
      if (anchor == null || anchor.isEmpty) return null;

      final ok = await Ed25519Keys.verifyBase64(
        anchor,
        context.signingBytes(plaintext),
        signatureB64,
      );
      if (!ok) {
        logger.warning(
          'Message ${context.messageId} in chat ${context.chatId}: identity '
          'signature INVALID for sender ${context.senderId}',
          tag: 'MessageSignatureVerifier',
        );
      }
      return ok ? MessageSigStatus.valid : MessageSigStatus.invalid;
    } catch (e) {
      logger.warning(
        'Signature verification errored for ${context.messageId}: $e',
        tag: 'MessageSignatureVerifier',
      );
      return null;
    }
  }
}

final messageSignatureVerifierProvider =
    Provider<MessageSignatureVerifier>((ref) {
  return MessageSignatureVerifier(ref);
});
