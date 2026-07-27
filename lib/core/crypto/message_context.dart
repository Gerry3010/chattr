// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// The (chat, sender, message) tuple an encrypted envelope is bound to.
///
/// Used twice by the v4 envelope (audit M3 + H1):
///   • [aadBytes] go into the AES-GCM DEM as *additional authenticated data*,
///     so a ciphertext row cannot be spliced into another chat/message or
///     relabelled to a different sender — decryption itself fails.
///   • [signingBytes] (context ‖ plaintext) are what the sender's Ed25519
///     identity key signs, so recipients can verify authorship even against
///     the server.
///
/// Byte layout uses NUL separators between the UTF-8 fields (UUIDs and the
/// 'system' sender contain no NUL), so variable-length ids can't be shifted
/// into one another. These byte layouts are mirrored in
/// `mcp_server/src/crypto_port.ts` and
/// `supabase/functions/insert-system-message/index.ts` — change all together.
class MessageContext {
  static const String _aadLabel = 'chattr-msg-aad-v1';
  static const String _sigLabel = 'chattr-msg-sig-v1';

  final String chatId;
  final String senderId;
  final String messageId;

  const MessageContext({
    required this.chatId,
    required this.senderId,
    required this.messageId,
  });

  Uint8List _joined(String label, [String? plaintext]) {
    final b = BytesBuilder();
    b.add(utf8.encode(label));
    b.addByte(0);
    b.add(utf8.encode(chatId));
    b.addByte(0);
    b.add(utf8.encode(senderId));
    b.addByte(0);
    b.add(utf8.encode(messageId));
    if (plaintext != null) {
      b.addByte(0);
      b.add(utf8.encode(plaintext));
    }
    return b.toBytes();
  }

  /// AAD for the AES-GCM DEM layer of a v4 envelope.
  Uint8List aadBytes() => _joined(_aadLabel);

  /// The exact bytes the sender's identity key signs for [plaintext].
  Uint8List signingBytes(String plaintext) => _joined(_sigLabel, plaintext);
}
