// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/logger_service.dart';
import 'identity_key_manager.dart';
import 'kem_key_binding.dart';
import 'security_providers.dart';

/// Signs a per-chat KEM public-key blob with this device's identity key before
/// it is registered on the server (audit C1). Shared by every registration
/// path: chat creation/refresh/rotation (ChatsController), QR/manual joins,
/// MCP auto-join and recovery reconciliation.
///
/// Falls back to the unsigned blob on any error — peers then see the key as
/// "unverified" rather than the registration failing.
class KemKeySigner {
  final IdentityKeyManager _identity;

  KemKeySigner(this._identity);

  Future<String> sign(String chatId, String publicBlob) async {
    try {
      await _identity.ensureKeyPair();
      final sig =
          await _identity.sign(KemKeyBinding.bindingMessage(chatId, publicBlob));
      return KemKeyBinding.attachSignature(publicBlob, sig);
    } catch (e) {
      logger.warning(
        'Could not sign KEM key for chat $chatId; registering unsigned',
        tag: 'KemKeySigner',
        error: e,
      );
      return publicBlob;
    }
  }
}

final kemKeySignerProvider = Provider<KemKeySigner>((ref) {
  return KemKeySigner(ref.read(identityKeyManagerProvider));
});
