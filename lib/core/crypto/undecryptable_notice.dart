// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'envelope_version.dart';

/// Stands in for a message this device received but cannot open.
///
/// Before this existed such a message was only logged ("Failed to process
/// missed message …") and never appeared in the chat, so neither side knew
/// something had been said. Shaped like [UnsupportedEnvelopeNotice] so it
/// travels the same paths: plain text to storage, a card in the chat.
///
/// [reason] says which kind it is, because the two are handled differently:
/// - [prekey]: wrapped to a one-time key this device does not hold. That does
///   not get better, so the message is acknowledged and the retries stop.
///   Usually the account was recovered on another device; a wiped local
///   database or a duplicate of an already opened message look the same.
/// - [keys]: no chat key opened it. May be temporary, so the server copy
///   stays and a later successful decrypt replaces this notice.
class UndecryptableNotice {
  static const String key = '_chattr_undecryptable';
  static const String prekey = 'prekey';
  static const String keys = 'keys';

  const UndecryptableNotice(this.reason);

  final String reason;

  String encode() => jsonEncode({key: 1, 'r': reason});

  /// Parses a stored notice, or null if [body] is not one.
  static UndecryptableNotice? tryParse(String? body) {
    if (body == null || !body.contains(key)) return null;
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      if (m[key] == null) return null;
      final r = m['r'];
      return UndecryptableNotice(r is String ? r : keys);
    } catch (_) {
      // A notice standing in for a SYSTEM message was stored in Dart's map
      // notation until 2026-10-24 (`{_chattr_undecryptable: 1, r: keys}`,
      // see SystemMessage.withDecryptedContent). Those rows stay readable.
      final legacy = _mapNotation.firstMatch(body.trim());
      return legacy == null ? null : UndecryptableNotice(legacy.group(1)!);
    }
  }

  static final _mapNotation = RegExp(
    r'^\{_chattr_undecryptable: 1, r: (\w+)\}$',
  );
}

/// What to do with a message that failed to decrypt.
enum UndecryptableAction {
  /// Store the notice and mark the message received (no more retries).
  storeAndAcknowledge,

  /// Store the notice, leave the server copy for a later retry.
  storeOnly,

  /// The device already holds the real content (an earlier attempt worked,
  /// only the acknowledgement got lost): never overwrite it, just acknowledge.
  acknowledgeOnly,

  /// The real content is here and the failure may be temporary: do nothing.
  ignore,
}

/// Pure rule for [UndecryptableAction].
///
/// [definitive] is true for a missing one-time key. [existingContent] is what
/// the local database already holds for this message id, if anything.
UndecryptableAction undecryptableAction({
  required bool definitive,
  required String? existingContent,
}) {
  final hasRealContent =
      existingContent != null &&
      existingContent.isNotEmpty &&
      UndecryptableNotice.tryParse(existingContent) == null &&
      UnsupportedEnvelopeNotice.tryParse(existingContent) == null;
  if (hasRealContent) {
    return definitive
        ? UndecryptableAction.acknowledgeOnly
        : UndecryptableAction.ignore;
  }
  return definitive
      ? UndecryptableAction.storeAndAcknowledge
      : UndecryptableAction.storeOnly;
}
