// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

/// Rounds an encrypted envelope up to a fixed size grid, so the row the server
/// stores no longer measures the message that went into it.
///
/// **Why this is needed.** AES-GCM is a stream mode: the ciphertext is exactly
/// as long as the plaintext. The content is unreadable, but the *length* is
/// not — and `messages.encrypted_content` is a column the server can measure
/// at leisure, next to sender, recipient, chat and timestamp. A two-character
/// answer to a question is almost certainly "ja" or "ok"; a single emoji has a
/// different length than a sentence; and where the set of plausible messages is
/// small (one of five addresses, a name, a time) the length alone often cuts it
/// down to one. Over a conversation, lengths and gaps sketch its shape.
///
/// **Why in the envelope and not in the plaintext.** Padding the plaintext
/// would need every recipient to strip it again — which means a new envelope
/// version, and an older client that meets a version it doesn't know throws
/// (`Unsupported message version`) and loses the message permanently, because
/// its sync watermark moves past the row it couldn't read. Padding the
/// *envelope* avoids that entirely: all three implementations that read an
/// envelope (Dart [MessageEncryptionService], `mcp_server/src/crypto_port.ts`,
/// `supabase/functions/insert-system-message/index.ts`) parse the JSON and read
/// named fields — an unknown one is never looked at. So `v` stays 4/5, the
/// plaintext, the AAD and the identity signature are all untouched, and a
/// client that has never heard of padding reads a padded message exactly as
/// before. Nothing to roll out, nothing to gate, nothing that can be lost.
///
/// **Why the filler is random.** A run of one repeated character would be
/// squeezed flat by Postgres' TOAST compression, which kicks in for larger
/// values — the stored size would then track the real length again and hand
/// back precisely what the padding was meant to take away. Random characters
/// don't compress.
///
/// **What this does NOT hide.** The *approximate* length still shows: padding
/// puts a message into a bucket, it does not make all messages equal. And it
/// says nothing about **when** and **how often** — that four messages passed
/// between two people at 23:40 is as visible as before. This closes one gap,
/// not the category.
class EnvelopePadding {
  /// The grid, in characters of the serialised envelope.
  ///
  /// 256 sits in a deliberate spot. A hybrid envelope already carries a
  /// ~1.5 KB ML-KEM ciphertext, so the baseline dwarfs the message: 256 costs
  /// at most about a seventh on top, while swallowing roughly 190 characters
  /// of plaintext difference — which covers the whole range where guessing is
  /// easy ("ja" / "nein" / "bin unterwegs"). Raising it buys a wider bucket at
  /// a proportional price; the value is the only thing that needs changing.
  static const int bucket = 256;

  /// Characters the filler is drawn from — the base64 alphabet, so the filler
  /// looks like the ciphertext around it and needs no JSON escaping (which
  /// would make the final length unpredictable).
  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /// The field the filler rides in. One letter on purpose: the name is pure
  /// overhead, repeated on every row.
  static const String field = 'x';

  /// Cost of inserting `,"x":""` into an existing JSON object.
  static const int _wrapperCost = 7;

  /// [envelopeJson] rounded up to the next multiple of [bucket].
  ///
  /// Returns the input unchanged if it is not a JSON object, or if it is an
  /// empty one — `{,"x":""}` would not be valid JSON, and an envelope without
  /// fields is not something worth padding anyway.
  static String pad(String envelopeJson, {int bucket = bucket, Random? random}) {
    if (bucket <= 0) return envelopeJson;
    if (!envelopeJson.startsWith('{') || !envelopeJson.endsWith('}')) {
      return envelopeJson;
    }
    if (envelopeJson.length <= 2) return envelopeJson;

    final current = envelopeJson.length;
    // The smallest total we can actually reach: anything below leaves no room
    // for the wrapper, so we take the next grid line up.
    var target = ((current + _wrapperCost) / bucket).ceil() * bucket;
    if (target - current < _wrapperCost) target += bucket;

    final fillerLength = target - current - _wrapperCost;
    final filler = _randomFiller(fillerLength, random ?? _secureRandom);
    return '${envelopeJson.substring(0, envelopeJson.length - 1)}'
        ',"$field":"$filler"}';
  }

  static final Random _secureRandom = Random.secure();

  static String _randomFiller(int length, Random random) {
    if (length <= 0) return '';
    final buf = StringBuffer();
    for (var i = 0; i < length; i++) {
      buf.write(_alphabet[random.nextInt(_alphabet.length)]);
    }
    return buf.toString();
  }
}
