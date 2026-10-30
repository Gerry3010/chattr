// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/chat_key_pair_manager.dart';
import '../../core/security/identity_key_manager.dart';
import '../../core/security/kem_key_signer.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';

/// After a recovery-phrase login the device has the identity back (server-side
/// memberships intact) but NO per-chat keypairs — they lived only on the lost
/// device. For every chat the user is still a member of but has no local
/// keypair, generate a fresh one and publish its public key so senders start
/// encrypting to it again. Messages sent to the old key before this point stay
/// undecryptable (consistent with the "no history" recovery scope).
///
/// RLS: a member may update their OWN chat_members row's public_key
/// ("Members can update their own record", migration 00005).
class RecoveryKeyReconciler {
  final SupabaseClient _client;
  final ChatKeyPairManager _keyManager;
  final IdentityKeyManager _identityKeyManager;
  final KemKeySigner _signer;

  RecoveryKeyReconciler(
    this._client,
    this._keyManager,
    this._identityKeyManager,
    this._signer,
  );

  Future<void> reconcile(String userId) async {
    // Identity key (Signal model, audit C1): a recovered account lands on a
    // device without one, so ensureKeyPair mints a FRESH identity key here —
    // peers see a "safety number changed" warning and re-verify. Publishing it
    // before the per-chat keys means the signed chat keys below verify
    // immediately. (ensureKeyPair is idempotent, so reconcile stays re-runnable.)
    try {
      final identityPub = await _identityKeyManager.ensureKeyPair();
      await _client
          .from('profiles')
          .update({'identity_public_key': identityPub}).eq('id', userId);
      // Recorded as OUR publish, so the installation we replaced is the one
      // that recognises itself as superseded, not this one.
      await _identityKeyManager.markPublished(identityPub);
      logger.info('Republished identity key after recovery', tag: 'Recovery');
    } catch (e) {
      logger.warning('Identity key republish failed: $e', tag: 'Recovery');
    }

    final List<dynamic> rows = await _client
        .from('chat_members')
        .select('chat_id')
        .eq('user_id', userId);

    for (final row in rows) {
      final chatId = row['chat_id'] as String;
      try {
        if (await _keyManager.hasKeyPair(chatId)) continue;
        await _keyManager.generateKeyPairForChat(chatId);
        final publicKey = await _keyManager.getPublicKey(chatId);
        if (publicKey == null) continue;
        await _client
            .from('chat_members')
            .update({'public_key': await _signer.sign(chatId, publicKey)})
            .match({'chat_id': chatId, 'user_id': userId});
        logger.info('Republished key for recovered chat $chatId', tag: 'Recovery');
      } catch (e) {
        logger.warning('Key reconcile failed for chat $chatId: $e', tag: 'Recovery');
      }
    }
  }
}

final recoveryKeyReconcilerProvider = Provider<RecoveryKeyReconciler>((ref) {
  return RecoveryKeyReconciler(
    ref.read(supabaseClientProvider),
    ref.read(chatKeyPairManagerProvider),
    ref.read(identityKeyManagerProvider),
    ref.read(kemKeySignerProvider),
  );
});
