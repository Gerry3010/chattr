// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../profiles/profiles_controller.dart';
import '../../core/crypto/message_context.dart';
import '../../core/events/event_types.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/kem_key_binding.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chat_member_keys_repository.dart';
import '../identity/identity_verification_repository.dart';
import '../identity/message_signature_verifier.dart';
import 'call_signal.dart';

/// The peer can't take a call yet: no chat key, or one from a client that
/// predates key signing. A signal sealed to it would come out unsigned (v3),
/// and the receiving side refuses unsigned signals — so don't even ring.
class CallPeerNotReady implements Exception {
  const CallPeerNotReady();
}

/// The peer's chat key carries a signature that does NOT match the identity
/// we pinned for them: someone swapped the key. Messages only warn about this;
/// a call refuses, because there is no "read it later and judge".
class CallPeerKeyMismatch implements Exception {
  const CallPeerKeyMismatch();
}

/// Seals call signals like messages and ships them through
/// `send_call_signal` (00085); opens and verifies the ones that arrive.
///
/// The seal is the point. The SDP carries the DTLS fingerprints that key the
/// audio — a party able to swap them in transit could sit in the middle of the
/// call. Each signal is therefore encrypted to the peer's chat key AND signed
/// with our identity key, AAD-bound to `call:<chat>‖sender‖signal-id`. The
/// server sees an opaque blob and who sent it to whom; it cannot read or
/// forge one.
///
/// No prekeys: a call signal must not burn a one-time prekey the next real
/// message needs, and forward secrecy for a few seconds of SDP buys nothing.
class CallSignaling {
  CallSignaling(this._ref);

  final Ref _ref;

  /// [kind] tells the server what it may push for (00088): 'invite' wakes
  /// a closed app and keeps the sealed invite until fetched, 'cancel' takes
  /// the ringing down again. Everything else travels the bus only.
  Future<void> send({
    required String chatId,
    required String peerId,
    required CallSignal signal,
    String? kind,
  }) async {
    final myId = _ref.read(authControllerProvider);
    if (myId == null) throw StateError('not signed in');

    final peerPub = await _ref
        .read(chatMemberKeysRepositoryProvider)
        .getPublicKey(chatId: chatId, userId: peerId);
    if (peerPub == null || KemKeyBinding.signatureOf(peerPub) == null) {
      throw const CallPeerNotReady();
    }
    final pins = _ref.read(identityVerificationRepositoryProvider);
    var anchor = await pins.pinnedKey(peerId);
    if (anchor == null) {
      // No pin yet: trust on first use, as a message would (CHAT-42). Without
      // this, a call to someone never pinned went out against whatever key
      // the server handed over, unchecked.
      final published = await _publishedIdentityKey(peerId);
      if (published != null) {
        await pins.pin(peerId, published, verified: false);
        anchor = published;
      }
    }
    if (anchor != null &&
        !await KemKeyBinding.verify(chatId, peerPub, anchor)) {
      throw const CallPeerKeyMismatch();
    }

    final signalId = const Uuid().v4();
    final ctx = MessageContext(
      chatId: callSignalContextChatId(chatId),
      senderId: myId,
      messageId: signalId,
    );
    final plaintext = signal.encode();
    // Unlike a message, an unsigned signal is worthless — the receiver drops
    // it. So a signing failure throws instead of degrading.
    final sig = await _ref
        .read(identityKeyManagerProvider)
        .sign(ctx.signingBytes(plaintext));
    final envelope = await _ref
        .read(messageEncryptionServiceProvider)
        .encryptForRecipient(plaintext, peerPub,
            context: ctx, signatureB64: sig);

    await _ref.read(supabaseClientProvider).rpc<void>(
      'send_call_signal',
      params: {
        'p_chat_id': chatId,
        'p_to': peerId,
        'p_signal_id': signalId,
        'p_envelope': envelope,
        'p_kind': ?kind,
      },
    );
  }

  Future<String?> _publishedIdentityKey(String userId) async {
    try {
      final profile = await _ref
          .read(profilesControllerProvider.notifier)
          .getProfile(userId)
          .timeout(const Duration(seconds: 5));
      final key = profile.identityPublicKey;
      return (key == null || key.isEmpty) ? null : key;
    } catch (_) {
      return null;
    }
  }

  /// The sealed invite a push woke us for (00088): once, only ours, only
  /// while fresh. Null when it is gone — taken, expired, or never ours.
  Future<CallSignalEvent?> fetchInvite(String signalId) async {
    final rows = await _ref.read(supabaseClientProvider).rpc<dynamic>(
      'fetch_call_invite',
      params: {'p_signal_id': signalId},
    );
    if (rows is! List || rows.isEmpty) return null;
    final r = rows.first as Map;
    return CallSignalEvent(
      chatId: r['chat_id'] as String,
      senderId: r['sender_id'] as String,
      signalId: signalId,
      envelope: r['envelope'] as String,
    );
  }

  /// Whether [peerId]'s app can take a call at all (00087). Clients before
  /// 1.32 never announce it; ringing them would ring into the void. A failed
  /// lookup says yes — then the call fails where it would have anyway, rather
  /// than a network hiccup blocking every call.
  Future<bool> peerCanTakeCalls({
    required String chatId,
    required String peerId,
  }) async {
    try {
      final r = await _ref.read(supabaseClientProvider).rpc<dynamic>(
        'peer_can_take_calls',
        params: {'p_chat_id': chatId, 'p_peer': peerId},
      );
      return r != false;
    } catch (e) {
      logger.warning('peer_can_take_calls failed: $e', tag: 'Calls');
      return true;
    }
  }

  /// Opens [event]. Returns null — and logs why — for anything that is not a
  /// fresh, validly signed call signal from the sender the server named.
  Future<CallSignal?> open(CallSignalEvent event, {DateTime? now}) async {
    try {
      final ctx = MessageContext(
        chatId: callSignalContextChatId(event.chatId),
        senderId: event.senderId,
        messageId: event.signalId,
      );
      final keys =
          await _ref.read(chatKeyPairManagerProvider).getAllPrivateKeys(
                event.chatId,
              );
      // No prekeyResolver: a v5 envelope throws here, which is right — we
      // never send one, so one arriving is not ours.
      final env = await _ref
          .read(messageEncryptionServiceProvider)
          .decryptEnvelopeTryKeys(event.envelope, keys, context: ctx);
      if (env.version < 4) {
        logger.warning('Call signal below v4 dropped', tag: 'Calls');
        return null;
      }
      final status = await _ref.read(messageSignatureVerifierProvider).verify(
            context: ctx,
            plaintext: env.plaintext,
            signatureB64: env.signatureB64,
            envelopeVersion: env.version,
          );
      if (status != MessageSigStatus.valid) {
        logger.warning('Call signal with signature "$status" dropped',
            tag: 'Calls');
        return null;
      }
      final signal = CallSignal.tryDecode(env.plaintext);
      if (signal == null) {
        logger.warning('Malformed call signal dropped', tag: 'Calls');
        return null;
      }
      if (!signal.isFresh(now ?? DateTime.now())) {
        logger.warning('Stale call signal dropped (replay?)', tag: 'Calls');
        return null;
      }
      return signal;
    } catch (e) {
      logger.warning('Call signal could not be opened: $e', tag: 'Calls');
      return null;
    }
  }
}

final callSignalingProvider = Provider<CallSignaling>(CallSignaling.new);
