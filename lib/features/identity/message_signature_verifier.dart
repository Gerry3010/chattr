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

  MessageSigStatus._();
}

/// Verifies a decrypted message's identity signature against the sender's
/// pinned identity key (TOFU via the peer's profile when nothing is pinned
/// yet). Returns:
///   • [MessageSigStatus.valid] / [MessageSigStatus.invalid] when a signature
///     was present and could be checked,
///   • null when there is nothing to check (unsigned legacy/v3 message, or the
///     sender has no published identity key to check against).
class MessageSignatureVerifier {
  final Ref _ref;

  MessageSignatureVerifier(this._ref);

  Future<String?> verify({
    required MessageContext context,
    required String plaintext,
    required String? signatureB64,
  }) async {
    if (signatureB64 == null || signatureB64.isEmpty) return null;
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
