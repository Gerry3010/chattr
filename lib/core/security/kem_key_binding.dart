// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/ed25519.dart';

/// Binds a per-chat hybrid KEM public key to its owner's long-term **identity**
/// key (Ed25519), closing the audit's C1 MITM hole: a hostile server can write
/// any bytes into `chat_members.public_key`, but it cannot forge a signature by
/// the peer's pinned identity key over those bytes.
///
/// The owner signs `LABEL ‖ chatId ‖ x25519Pub ‖ mlkemPub` with its identity
/// key and stores the base64 signature in an extra `"s"` field of the existing
/// public-key blob (`{"x":..,"m":..}` → `{"x":..,"m":..,"s":..}`). The extra
/// field is ignored by every consumer that only decrypts (Dart
/// [ChatKeyPairManager.decodePublic], the MCP server, the edge function), so no
/// wire/format change is needed there — only the client that *verifies* peers
/// looks at `"s"`. Binding `chatId` prevents a signed blob from being replayed
/// into a different chat.
class KemKeyBinding {
  static const String _label = 'chattr-kem-identity-binding-v1';

  /// The exact bytes an identity key signs to vouch for [publicBlob] in [chatId].
  static Uint8List bindingMessage(String chatId, String publicBlob) {
    final m = jsonDecode(publicBlob) as Map<String, dynamic>;
    final xPub = base64.decode(m['x'] as String);
    final mPub = base64.decode(m['m'] as String);
    final b = BytesBuilder();
    b.add(utf8.encode(_label));
    b.add(utf8.encode(chatId));
    b.add(xPub);
    b.add(mPub);
    return b.toBytes();
  }

  /// Return [publicBlob] with the identity signature attached under `"s"`.
  static String attachSignature(String publicBlob, String signatureB64) {
    final m = Map<String, dynamic>.from(
        jsonDecode(publicBlob) as Map<String, dynamic>);
    m['s'] = signatureB64;
    return jsonEncode(m);
  }

  /// The base64 identity signature in a public-key blob, or null if unsigned.
  static String? signatureOf(String blob) {
    try {
      final m = jsonDecode(blob) as Map<String, dynamic>;
      final s = m['s'];
      return s is String ? s : null;
    } catch (_) {
      return null;
    }
  }

  /// Verify that [blob]'s `"s"` is a valid identity signature over the KEM key
  /// bound to [chatId], produced by the identity key [identityPublicB64].
  /// Returns false (fails closed) if unsigned or malformed.
  static Future<bool> verify(
    String chatId,
    String blob,
    String identityPublicB64,
  ) async {
    final sig = signatureOf(blob);
    if (sig == null) return false;
    return Ed25519Keys.verifyBase64(
      identityPublicB64,
      bindingMessage(chatId, blob),
      sig,
    );
  }
}
