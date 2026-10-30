// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/logger_service.dart';
import '../../features/prekeys/prekey_local_repository.dart';
import '../../features/prekeys/prekey_repository.dart';
import 'chat_key_pair_manager.dart';
import 'kem_key_signer.dart';

/// A prekey claimed for a recipient: which prekey id was consumed + its
/// identity-signed public blob (`{"x":..,"m":..,"s":..}`) to wrap the message
/// key to. Returned by [PrekeyManager.claimForRecipient].
class ClaimedPrekey {
  final String prekeyId;
  final String publicBlob;
  const ClaimedPrekey({required this.prekeyId, required this.publicBlob});
}

/// Orchestrates the one-time KEM prekey pool for forward secrecy (audit P3):
/// generates + publishes my prekeys (public → server, private → local SQLite),
/// claims a peer's prekey when sending (envelope v5), and consumes+deletes my
/// own prekey when an incoming v5 message used it (the forward-secrecy act).
///
/// A prekey is just another detached hybrid keypair
/// ([ChatKeyPairManager.generateDetachedKeyPair]); the public half is signed by
/// the identity key exactly like a static chat KEM key ([KemKeySigner]), so
/// peers verify it against the same pinned identity — no new trust primitive.
class PrekeyManager {
  final PrekeyLocalRepository _local;
  final PrekeyRepository _remote;
  final KemKeySigner _signer;

  PrekeyManager(this._local, this._remote, this._signer);

  /// How many prekeys to keep available on the server per chat.
  static const int targetPoolSize = 20;

  /// Replenish once the available pool drops below this (avoids a publish on
  /// every send while never letting the pool run dry between top-ups).
  static const int replenishThreshold = 8;

  static final Random _rng = Random.secure();

  String _newPrekeyId() {
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => _rng.nextInt(256)),
    );
    return base64Url.encode(bytes);
  }

  /// Top the SERVER pool up to [targetPoolSize] if it has fallen below
  /// [replenishThreshold]. Publishes the public halves (identity-signed) and
  /// stores the private halves locally. Best-effort: logs and returns on error
  /// (the sender-side v5→v4 fallback keeps messaging working regardless).
  ///
  /// First it removes my server prekeys whose private half this device does
  /// not hold ([orphanPrekeyIds]). Those come from another installation of the
  /// same account: the device before a recovery, a wiped local database, a
  /// reinstall. `claim_prekey` hands out the OLDEST prekey first, so without
  /// this a peer would keep wrapping messages to keys that exist nowhere on
  /// this device, every one of them undecryptable here ("prekey … unavailable"),
  /// and the pool would still count as full, so no fresh prekeys were published.
  /// Chattr has one device per account; with multi-device, prekeys must become
  /// per device before this may run, or devices would delete each other's.
  Future<void> replenishIfLow(String chatId, String userId) async {
    try {
      final onServer = await _remote.unconsumedIds(
        chatId: chatId,
        userId: userId,
      );
      final orphans = orphanPrekeyIds(onServer, await _local.idsForChat(chatId));
      if (orphans.isNotEmpty) {
        await _remote.deleteMine(
          chatId: chatId,
          userId: userId,
          prekeyIds: orphans,
        );
        logger.info(
          'Removed ${orphans.length} prekey(s) without a local private half '
          'in chat $chatId (published by another installation)',
          tag: 'PrekeyManager',
        );
      }
      final available = onServer.length - orphans.length;
      if (available >= replenishThreshold) return;

      final need = targetPoolSize - available;
      final toPublish = <PublishedPrekey>[];
      for (var i = 0; i < need; i++) {
        final id = _newPrekeyId();
        final kp = await ChatKeyPairManager.generateDetachedKeyPair();
        // Sign the PUBLIC blob with the identity key, bound to chatId — the
        // signature commits to the exact key bytes, so a server that swaps the
        // prekey is caught by the recipient-side verify (same as static keys).
        final signed = await _signer.sign(chatId, kp.publicKey);
        await _local.insert(
          prekeyId: id,
          chatId: chatId,
          privateBlob: kp.privateKey,
        );
        toPublish.add(PublishedPrekey(prekeyId: id, publicBlob: signed));
      }
      await _remote.publish(
        chatId: chatId,
        userId: userId,
        prekeys: toPublish,
      );
      // Housekeeping: drop my already-consumed server rows so the pool table
      // doesn't grow unbounded (unconsumed ones are untouched).
      await _remote.deleteMyConsumed(chatId: chatId, userId: userId);
    } catch (e, st) {
      logger.warning(
        'Prekey replenish failed for chat $chatId; senders fall back to v4',
        tag: 'PrekeyManager',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Claim one unconsumed prekey of [recipientId] for a v5 send, or null when
  /// the recipient has none (older client / exhausted pool) → the caller wraps
  /// v4 instead. The claim is atomic server-side (SKIP LOCKED).
  Future<ClaimedPrekey?> claimForRecipient({
    required String chatId,
    required String recipientId,
  }) async {
    final claimed = await _remote.claim(chatId: chatId, recipientId: recipientId);
    if (claimed == null) return null;
    return ClaimedPrekey(
      prekeyId: claimed.prekeyId,
      publicBlob: claimed.publicBlob,
    );
  }

  /// The private-key blob (`{"x":..,"m":..}`) for one of MY prekeys, to unwrap
  /// an incoming v5 message. Null if already consumed/unknown → caller reports a
  /// decrypt miss (the sender will re-send or it is a replay).
  Future<String?> privateBlobFor(String prekeyId) =>
      _local.privateBlobFor(prekeyId);

  /// Delete one of MY prekeys' private half — the forward-secrecy act. Call
  /// ONCE, after an incoming v5 message has been decrypted AND persisted, and
  /// NEVER on a local re-decrypt of already-stored rows.
  Future<void> consume(String prekeyId) => _local.delete(prekeyId).then((_) {});

  /// Drop all local private prekeys for a chat (leave / key wipe).
  Future<void> deleteForChat(String chatId) => _local.deleteForChat(chatId);
}

/// The prekeys I have on the server but cannot decrypt for: published, still
/// unconsumed, and with no private half on this device. Pure for testing.
List<String> orphanPrekeyIds(Iterable<String> onServer, Set<String> local) =>
    [for (final id in onServer) if (!local.contains(id)) id];

final prekeyManagerProvider = Provider<PrekeyManager>((ref) {
  return PrekeyManager(
    ref.read(prekeyLocalRepositoryProvider),
    ref.read(prekeyRepositoryProvider),
    ref.read(kemKeySignerProvider),
  );
});
