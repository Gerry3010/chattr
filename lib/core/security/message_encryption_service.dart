// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;

import '../crypto/envelope_padding.dart';
import '../crypto/envelope_version.dart';
import '../crypto/message_context.dart';
import '../crypto/ml_kem.dart';
import 'chat_key_pair_manager.dart';
import 'kem_key_binding.dart';

/// Media blobs at or above this size are decrypted on a background isolate (via
/// [compute]) so the AES-GCM work doesn't block the UI thread — the on-main-
/// thread decrypt is what made the video/gallery load spinner jank. Smaller
/// blobs (thumbnails) stay inline: an isolate hop would cost more than it saves.
const int _offThreadDecryptThreshold = 256 * 1024;

/// Runs off the UI isolate (via [compute]): recreate the cipher and decrypt one
/// `nonce ++ ciphertext ++ tag` blob. Top-level with a record argument so it is
/// [compute]-sendable. On web there are no isolates, so [compute] runs this on
/// the main thread — unavoidable, but web is desktop-class RAM/CPU anyway.
Future<Uint8List> _decryptBlobOffThread(
  (Uint8List blob, Uint8List key, List<int> aad) args,
) async {
  final (blob, key, aad) = args;
  final aesGcm = AesGcm.with256bits();
  final nonce = blob.sublist(0, 12);
  final mac = blob.sublist(blob.length - 16);
  final ct = blob.sublist(12, blob.length - 16);
  final plain = await aesGcm.decrypt(
    SecretBox(ct, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(key),
    aad: aad,
  );
  return Uint8List.fromList(plain);
}

/// A decrypted envelope: the plaintext plus the metadata the caller needs to
/// verify authorship (audit H1) — the sender's identity signature (base64, v4
/// only) and the envelope version it arrived in.
class DecryptedEnvelope {
  final String plaintext;
  final String? signatureB64;
  final int version;

  /// For a v5 (forward-secret) envelope: the one-time prekey id it consumed.
  /// The caller must delete that prekey's private half AFTER persisting the
  /// message (the forward-secrecy act) — and only at a consume-once site, never
  /// on a local re-decrypt. Null for v3/v4.
  final String? prekeyId;

  const DecryptedEnvelope({
    required this.plaintext,
    required this.version,
    this.signatureB64,
    this.prekeyId,
  });
}

/// One recipient's claimed one-time prekey for a v5 send: the prekey id (echoed
/// into the envelope as `pk`) and its identity-signed public blob
/// (`{"x":..,"m":..,"s":..}`) to wrap the message key to.
typedef RecipientPrekey = ({String prekeyId, String publicBlob});

/// Message Encryption Service (post-quantum hybrid).
///
/// KEM-DEM scheme:
///   - A random 32-byte message key encrypts the plaintext once with AES-256-GCM
///     (the DEM layer, pure Dart `cryptography`, identical on native and web).
///   - That message key is wrapped **per recipient** with the hybrid KEM
///     (X25519 + ML-KEM-768) via the platform facade (native FFI / web JS). The
///     wire format of the wrapped key is byte-identical across platforms.
///
/// Per-recipient payload (JSON):
///   v3 (legacy, decrypt-only): `{"v":3,"alg":"hybrid-kem:aes-gcm",`
///     `"ek":base64(wrapped key),"msg":base64(nonce ++ ciphertext ++ tag)}`
///   v4 (current): additionally binds the DEM to its (chat, sender, message)
///     context as AES-GCM AAD (audit M3 — no splice/relabel/replay), prefixes
///     the wrapped key with a scheme byte 0x02 and hard-rejects anything that
///     isn't full hybrid KEM (audit H2 — no silent X25519-only downgrade), and
///     carries the sender's identity signature in `sig` (audit H1):
///     `{"v":4,"alg":"hybrid-kem:aes-gcm","ek":base64(0x02 ++ wrapped key),`
///     `"msg":...,"sig":base64(Ed25519)}`
///   v5 (forward secrecy, P3): identical to v4 except the message key is wrapped
///     to a **one-time prekey** instead of the recipient's static chat key, and
///     the consumed prekey id rides in `pk`. The recipient decrypts once then
///     deletes that prekey — per-message forward secrecy:
///     `{"v":5,...,"ek":base64(0x02 ++ wrapped key),"pk":"<prekey id>",`
///     `"msg":...,"sig":base64(Ed25519)}`
///
/// The envelope shape (v3/v4/v5) is mirrored byte-for-byte by
/// `mcp_server/src/crypto_port.ts` and
/// `supabase/functions/insert-system-message/index.ts`.
class MessageEncryptionService {
  final ChatKeyPairManager _keyManager;

  MessageEncryptionService(this._keyManager);

  static final AesGcm _aesGcm = AesGcm.with256bits();

  /// Scheme byte prefixed to a v4 `ek`: full hybrid X25519+ML-KEM-768.
  static const int kemSchemeHybrid = 0x02;

  /// ML-KEM-768 sizes (FIPS 203).
  static const int _mlkemPubSize = 1184;
  static const int _mlkemCtSize = 1088;

  /// Minimum length of a hybrid-wrapped key: ephemeral X25519 pub (32) +
  /// ML-KEM ciphertext + AES-GCM nonce (12) + tag (16). Anything shorter is
  /// the legacy X25519-only format — which v4 rejects (downgrade protection).
  static const int _minHybridEkLen = 32 + _mlkemCtSize + 12 + 16;

  /// Encrypt for a single recipient (combined public-key blob).
  Future<String> encryptForRecipient(
    String plaintext,
    String publicKeyCombined, {
    MessageContext? context,
    String? signatureB64,
  }) async {
    final out = await encryptForAllMembers(
      plaintext,
      {'_': publicKeyCombined},
      context: context,
      signatureB64: signatureB64,
    );
    return out['_']!;
  }

  /// Encrypt for all members. Returns userId -> encrypted payload (JSON).
  ///
  /// With a [context] this emits v4 to recipients proven to run v4 (their KEM
  /// key is identity-signed — only v4 clients sign) and v3 to everyone else;
  /// without a context it emits v3 to all. This per-recipient gate is the v3→v4
  /// rollout-safety mechanism: a v3 client that receives a v4 message loses it
  /// permanently (watermark advances past the undecryptable row), and those v3
  /// clients are already deployed — so the ONLY place to protect them is here,
  /// at the sender. Fail-safe direction is v3 (v4 clients read v3).
  /// [recipientPrekeys] (forward secrecy, P3) maps a userId to a one-time
  /// prekey claimed for it. When present for a recipient (and it carries a
  /// signature), this emits **v5**: the message key is wrapped to that
  /// ephemeral prekey instead of the recipient's static chat key, and the
  /// prekey id rides in the `pk` field. The recipient decrypts once and deletes
  /// the prekey — forward secrecy per message. A recipient without a claimed
  /// prekey falls back to v4 (then v3): the same fail-safe, order-independent
  /// gate as v3→v4. The shared AAD-bound ciphertext (`msg`) and the identity
  /// signature are IDENTICAL for v4 and v5 recipients — only `ek`/`pk` differ
  /// per recipient. [minEnvelopeVersion] raises the envelope version when the
  /// content demands more of the reader than merely decrypting it — today
  /// exactly one case: a **shot** (v6, "view once"). The wire does not change
  /// for it; the number is the condition. A client that does not know it gets
  /// the "newer app version needed" card instead of a picture it would treat as
  /// an ordinary photo — the route via an unknown FIELD would be wrong here,
  /// because an unknown field is ignored, and that is precisely the harm. From
  /// 6 on the v3 fallback therefore also drops away: better to fail loudly than
  /// to break a promise quietly.
  Future<Map<String, String>> encryptForAllMembers(
    String plaintext,
    Map<String, String> memberKeys, {
    MessageContext? context,
    String? signatureB64,
    Map<String, RecipientPrekey>? recipientPrekeys,
    int minEnvelopeVersion = 3,
  }) async {
    // One ephemeral AES-256 message key + a single AES-GCM ciphertext, shared by
    // all recipients; only the wrapped key (ek) differs per recipient.
    final messageKey = _randomKey();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(messageKey),
      aad: context?.aadBytes() ?? const [],
    );
    final msgBlob = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    final msgB64 = base64.encode(msgBlob);

    // The v3 recipients (not yet on v4) can't use the AAD-bound v4 ciphertext,
    // so they share their own separate no-AAD copy — built lazily, once.
    Uint8List? legacyKey;
    String? legacyMsgB64;

    final out = <String, String>{};
    for (final entry in memberKeys.entries) {
      // ── Forward secrecy: v5 to a recipient we claimed a prekey for ────────
      // A claimed, signed prekey means the recipient runs v5 (⊇ v4). Wrap to
      // the ephemeral prekey instead of the static key; everything else (shared
      // AAD ciphertext, signature) is identical to v4. On any prekey shortfall
      // we simply fall through to the v4/v3 gate below — no message is lost.
      final prekey = recipientPrekeys?[entry.key];
      if (context != null && prekey != null) {
        final (pxPub, pmPub) = ChatKeyPairManager.decodePublic(prekey.publicBlob);
        if (pmPub.length == _mlkemPubSize &&
            KemKeyBinding.signatureOf(prekey.publicBlob) != null) {
          final ek = await mlKemEncryptDataKey(messageKey, pxPub, pmPub);
          out[entry.key] = EnvelopePadding.pad(jsonEncode({
            'v': minEnvelopeVersion > 5 ? minEnvelopeVersion : 5,
            'alg': 'hybrid-kem:aes-gcm',
            'ek': base64.encode(Uint8List.fromList([kemSchemeHybrid, ...ek])),
            'pk': prekey.prekeyId,
            'msg': msgB64,
            'sig': ?signatureB64,
          }));
          continue;
        }
      }

      final (xPub, mPub) = ChatKeyPairManager.decodePublic(entry.value);

      // ── Per-recipient version gate (P0 rollout safety) ────────────────────
      // Send v4 ONLY to a recipient we can prove runs v4: it has a bind-able
      // context, a full ML-KEM key, AND an identity-signed KEM key. Only a v4
      // client signs its KEM key (KemKeySigner); an unsigned key means a v3
      // client — and a v3 client that receives v4 loses the message PERMANENTLY
      // (its sync watermark advances past what it can't decrypt). So anything
      // not provably v4 gets v3, which v4 clients read fine. Fail-safe = v3.
      // This makes the v3→v4 rollout order-independent (no coordinated update).
      final recipientRunsV4 = context != null &&
          mPub.length == _mlkemPubSize &&
          KemKeyBinding.signatureOf(entry.value) != null;

      // `context != null` is a condition, not decoration: the shared ciphertext
      // was encrypted with the AAD, and a v6 reader requires it. Without a
      // context there would be an envelope nobody can open.
      if (recipientRunsV4 || (minEnvelopeVersion >= 6 && context != null)) {
        final ek = await mlKemEncryptDataKey(messageKey, xPub, mPub);
        out[entry.key] = EnvelopePadding.pad(jsonEncode({
          'v': minEnvelopeVersion > 4 ? minEnvelopeVersion : 4,
          'alg': 'hybrid-kem:aes-gcm',
          'ek': base64.encode(Uint8List.fromList([kemSchemeHybrid, ...ek])),
          'msg': msgB64,
          'sig': ?signatureB64,
        }));
      } else if (context == null) {
        // Context-less caller (e.g. tests): plain v3 with the shared no-AAD key.
        final ek = await mlKemEncryptDataKey(messageKey, xPub, mPub);
        out[entry.key] = EnvelopePadding.pad(jsonEncode({
          'v': 3,
          'alg': 'hybrid-kem:aes-gcm',
          'ek': base64.encode(ek),
          'msg': msgB64,
        }));
      } else {
        // A v3 recipient inside a v4-context send: separate no-AAD ciphertext.
        legacyKey ??= _randomKey();
        legacyMsgB64 ??= base64.encode(await _demEncrypt(legacyKey, plaintext));
        final ek = await mlKemEncryptDataKey(legacyKey, xPub, mPub);
        out[entry.key] = EnvelopePadding.pad(jsonEncode({
          'v': 3,
          'alg': 'hybrid-kem:aes-gcm',
          'ek': base64.encode(ek),
          'msg': legacyMsgB64,
        }));
      }
    }
    return out;
  }

  // One legacy-recipient DEM encryption (own key, no AAD).
  Future<Uint8List> _demEncrypt(Uint8List key, String plaintext) async {
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Decrypt a payload with the combined private-key blob, returning plaintext
  /// plus envelope metadata. v4 requires [context] (its DEM is AAD-bound to
  /// it); v3 ignores it. Wrong context => AES-GCM authentication fails.
  Future<DecryptedEnvelope> decryptEnvelope(
    String ciphertext,
    String privateKeyCombined, {
    MessageContext? context,
    Future<String?> Function(String prekeyId)? prekeyResolver,
  }) async {
    final payload = jsonDecode(ciphertext) as Map<String, dynamic>;
    final version = payload['v'];
    if (!EnvelopeVersions.supported.contains(version)) {
      // "Newer than I know" is the one decryption failure with a remedy the
      // user can act on, so it gets its own type — everything else stays a
      // generic failure, because telling someone to update over a damaged row
      // sends them after a fix that does not exist.
      if (version is int && EnvelopeVersions.isTooNew(version)) {
        throw EnvelopeTooNewException(version);
      }
      throw Exception('Unsupported message version: $version');
    }

    // v5 (forward secrecy): the unwrap key is a ONE-TIME prekey named by `pk`,
    // resolved from local storage — NOT the static chat key. Everything else
    // (hybrid scheme byte, AAD binding) matches v4.
    String? consumedPrekeyId;
    var keyBlob = privateKeyCombined;
    // v6 ("view once") sits on the wire like v4/v5; whether it was wrapped to a
    // one-time key is said by `pk` alone.
    final usesPrekey =
        version == 5 || (version == 6 && payload['pk'] is String);
    if (usesPrekey) {
      if (context == null) {
        throw Exception('v$version envelope needs a message context (AAD)');
      }
      final pk = payload['pk'];
      if (pk is! String) {
        throw Exception('v$version envelope missing prekey id');
      }
      if (prekeyResolver == null) {
        throw Exception('v$version envelope needs a prekey resolver');
      }
      final prekeyPriv = await prekeyResolver(pk);
      if (prekeyPriv == null) {
        throw Exception('prekey $pk unavailable (already consumed?)');
      }
      keyBlob = prekeyPriv;
      consumedPrekeyId = pk;
    }
    final (xPriv, mPriv) = ChatKeyPairManager.decodePrivate(keyBlob);

    var ek = base64.decode(payload['ek'] as String);
    List<int> aad = const [];
    if (version == 4 || version == 5 || version == 6) {
      if (context == null) {
        throw Exception('v$version envelope needs a message context (AAD)');
      }
      // Downgrade protection (audit H2): a v4/v5 wrapped key must be the full
      // hybrid scheme — reject unknown scheme bytes and anything short enough
      // to be the legacy X25519-only format.
      if (ek.isEmpty || ek[0] != kemSchemeHybrid) {
        throw Exception('v$version envelope with non-hybrid key scheme rejected');
      }
      ek = ek.sublist(1);
      if (ek.length < _minHybridEkLen) {
        throw Exception('v$version envelope with truncated hybrid key rejected');
      }
      aad = context.aadBytes();
    }

    final messageKey = await mlKemDecryptDataKey(
      Uint8List.fromList(ek),
      xPriv,
      mPriv,
    );

    final msgBlob = base64.decode(payload['msg'] as String);
    if (msgBlob.length < 12 + 16) {
      throw Exception('Ciphertext too short');
    }
    final nonce = msgBlob.sublist(0, 12);
    final mac = msgBlob.sublist(msgBlob.length - 16);
    final ct = msgBlob.sublist(12, msgBlob.length - 16);

    final plain = await _aesGcm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(messageKey),
      aad: aad,
    );
    final sig = payload['sig'];
    return DecryptedEnvelope(
      plaintext: utf8.decode(plain),
      version: version as int,
      signatureB64: sig is String ? sig : null,
      prekeyId: consumedPrekeyId,
    );
  }

  /// Decrypt a payload with the combined private-key blob (plaintext only).
  Future<String> decryptMessage(
    String ciphertext,
    String privateKeyCombined, {
    MessageContext? context,
  }) async {
    final env = await decryptEnvelope(
      ciphertext,
      privateKeyCombined,
      context: context,
    );
    return env.plaintext;
  }

  /// Convenience: decrypt for a chatId by loading its private key.
  Future<String> decryptMessageForChat(
    String ciphertext,
    String chatId, {
    MessageContext? context,
  }) async {
    final privateKey = await _keyManager.getPrivateKey(chatId);
    if (privateKey == null) {
      throw Exception('No private key found for chat $chatId');
    }
    return decryptMessage(ciphertext, privateKey, context: context);
  }

  /// Decrypt trying each candidate private key in order (current, then the
  /// retained previous generation after a key rotation). Returns the first
  /// success; rethrows the last error if none work.
  Future<DecryptedEnvelope> decryptEnvelopeTryKeys(
    String ciphertext,
    List<String> privateKeys, {
    MessageContext? context,
    Future<String?> Function(String prekeyId)? prekeyResolver,
  }) async {
    // A v5 envelope resolves its own (prekey) key by `pk` and ignores the static
    // candidate list, so trying it once is enough — but the static keys are also
    // the fallback for v3/v4, so keep the loop for those. On an empty list still
    // attempt once (v5 needs no static key) so a chat without a cached static
    // key can still decrypt a forward-secret message.
    final candidates = privateKeys.isEmpty ? const [''] : privateKeys;
    Object? lastError;
    for (final key in candidates) {
      try {
        return await decryptEnvelope(
          ciphertext,
          key,
          context: context,
          prekeyResolver: prekeyResolver,
        );
      } on EnvelopeTooNewException {
        // No key helps against a version this build cannot read, and the
        // caller needs THIS type to tell the user something useful — wrapping
        // it in the generic failure below would hide the one error we can
        // actually explain.
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Decryption failed for all keys: $lastError');
  }

  /// Like [decryptEnvelopeTryKeys], returning only the plaintext.
  Future<String> decryptMessageTryKeys(
    String ciphertext,
    List<String> privateKeys, {
    MessageContext? context,
    Future<String?> Function(String prekeyId)? prekeyResolver,
  }) async {
    final env = await decryptEnvelopeTryKeys(
      ciphertext,
      privateKeys,
      context: context,
      prekeyResolver: prekeyResolver,
    );
    return env.plaintext;
  }

  /// Encrypt raw bytes (a media file) with a fresh AES-256-GCM key.
  ///
  /// Returns the self-contained blob `nonce ++ ciphertext ++ tag` to upload to
  /// storage, and the random `key` that must be wrapped per recipient inside
  /// the message envelope (so only members can later decrypt the blob).
  Future<({Uint8List blob, Uint8List key})> encryptBytes(List<int> data) async {
    final key = _randomKey();
    final box = await _aesGcm.encrypt(data, secretKey: SecretKey(key));
    final blob = Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    return (blob: blob, key: key);
  }

  /// Decrypt a media blob produced by [encryptBytes] with its [key]. Large
  /// blobs are decrypted off the UI thread ([_decryptBlobOffThread]) to keep the
  /// load spinner smooth; small ones stay inline.
  Future<Uint8List> decryptBytes(Uint8List blob, Uint8List key) async {
    if (blob.length < 12 + 16) {
      throw Exception('Media blob too short');
    }
    if (blob.length >= _offThreadDecryptThreshold) {
      return compute(_decryptBlobOffThread, (blob, key, const <int>[]));
    }
    final nonce = blob.sublist(0, 12);
    final mac = blob.sublist(blob.length - 16);
    final ct = blob.sublist(12, blob.length - 16);
    final plain = await _aesGcm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plain);
  }

  /// A fresh random AES-256 media key. Public so the chunked-media path can
  /// reuse ONE key across all chunks of a file (each chunk still gets its own
  /// random nonce). See [encryptChunk].
  Uint8List newMediaKey() => _randomKey();

  /// Encrypt one chunk of a large media file with a caller-provided [key] (the
  /// per-file media key from [newMediaKey]) and [aad] that binds the chunk to
  /// its position — build it with [mediaChunkAad]. Returns the self-contained
  /// blob `nonce ++ ciphertext ++ tag`, identical framing to [encryptBytes] but
  /// per chunk. A fresh random nonce is generated per call (unique per chunk
  /// under the shared key).
  Future<Uint8List> encryptChunk(
    List<int> chunk,
    Uint8List key, {
    required List<int> aad,
  }) async {
    final box = await _aesGcm.encrypt(chunk, secretKey: SecretKey(key), aad: aad);
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Decrypt one chunk produced by [encryptChunk]. The [aad] MUST match what the
  /// sender used ([mediaChunkAad]) — a reordered, dropped, substituted or
  /// tampered chunk fails the GCM tag check and throws.
  Future<Uint8List> decryptChunk(
    Uint8List blob,
    Uint8List key, {
    required List<int> aad,
  }) async {
    if (blob.length < 12 + 16) {
      throw Exception('Media chunk too short');
    }
    // Chunks are multi-MiB → always decrypt off the UI thread.
    if (blob.length >= _offThreadDecryptThreshold) {
      return compute(_decryptBlobOffThread, (blob, key, aad));
    }
    final nonce = blob.sublist(0, 12);
    final mac = blob.sublist(blob.length - 16);
    final ct = blob.sublist(12, blob.length - 16);
    final plain = await _aesGcm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(plain);
  }

  /// Additional Authenticated Data binding a media chunk to its exact position:
  /// `<messageId>|<attIndex>|<chunkIndex>|<chunkCount>`. `chunkCount` rides in
  /// the identity-signed message envelope (v5), so the server can neither forge
  /// the count nor reorder/drop/splice chunks without a decrypt failure.
  static List<int> mediaChunkAad(
    String messageId,
    int attIndex,
    int chunkIndex,
    int chunkCount,
  ) =>
      utf8.encode('$messageId|$attIndex|$chunkIndex|$chunkCount');

  Uint8List _randomKey() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }
}
