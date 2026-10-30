// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

/// What this build knows how to open, and how it reacts to something newer.
///
/// **Why a number on top of the allowlist.** Decryption itself asks "is this
/// one of the versions I can read?" — an allowlist, which is the safer
/// question (a gap in the sequence must not become readable by accident).
/// But when the answer is no, the *reason* matters: a version ABOVE everything
/// this build knows means the sender is simply newer, and the honest reply is
/// "update the app". A version below or outside means something else — a
/// damaged row, a foreign format — and telling someone to update would send
/// them chasing a fix that isn't there.
///
/// **Why this exists before it is needed.** It cannot be retrofitted. A client
/// already in the field meets an unknown version, throws, and shows nothing at
/// all — silently. Whatever we do about that only helps builds shipped from
/// here on, so the notice has to be in place BEFORE the envelope version is
/// ever raised. If it is added at the same time as a v6, every device that
/// still needs to hear "please update" is exactly the one that cannot.
class EnvelopeVersions {
  /// Versions this build actually decrypts.
  ///
  /// **The only thing to change when a new envelope version arrives.** Add the
  /// number here in the same commit that teaches `MessageEncryptionService` to
  /// read it — see CLAUDE.md / AGENTS.md, where this is listed with the other
  /// places an envelope change has to touch. **v6 (1.27) — "view once".** On
  /// the wire v6 is identical to v4/v5: the same hybrid wrapping, the same AAD
  /// binding, the same signature; whether it was wrapped to a one-time key is
  /// said by the `pk` field, as with v5. The number carries **no** new crypto
  /// but a condition on the reader: "whoever opens this must understand that it
  /// only goes once."
  ///
  /// Why this has to be a version and not an unknown field — unlike the length
  /// padding, which deliberately travels in `x`: an unknown field is ignored,
  /// and that is exactly the harm here. An older client would treat the shot as
  /// an ordinary message and break the promise without anyone noticing. An
  /// unknown version throws — and since 1.25.1 "throws" no longer means
  /// "disappears": the client stores the placeholder, leaves the server copy
  /// standing and fetches the message again after the update. For a shot not
  /// yet opened that is exactly right.
  static const Set<int> supported = {3, 4, 5, 6};

  /// The highest envelope this build can open — **derived**, never typed by
  /// hand.
  ///
  /// A second hand-maintained constant would eventually drift from [supported],
  /// and the drift is silent in the dangerous direction: a max that ran ahead
  /// of the real support would classify a version as "known" that nothing can
  /// decrypt, and the message would go back to disappearing without a word —
  /// exactly the failure this file exists to prevent. Deriving it makes that
  /// state unrepresentable.
  static final int maxSupported = supported.reduce((a, b) => a > b ? a : b);

  /// The version stated by an envelope, or null if it does not state one.
  ///
  /// Deliberately forgiving about the surrounding JSON: this runs on data that
  /// already failed to decrypt, so it must not throw on its way to explaining
  /// why.
  static int? versionOf(String envelopeJson) {
    try {
      final v = (jsonDecode(envelopeJson) as Map<String, dynamic>)['v'];
      return v is int ? v : (v is String ? int.tryParse(v) : null);
    } catch (_) {
      return null;
    }
  }

  /// Is [version] newer than anything this build can read?
  static bool isTooNew(int? version) =>
      version != null && version > maxSupported;
}

/// Thrown when an envelope announces a version newer than [EnvelopeVersions.maxSupported].
///
/// Separate from a generic failure on purpose: this is the one decryption
/// error with a remedy the user can act on, and the only one where the message
/// is not damaged but merely out of reach.
class EnvelopeTooNewException implements Exception {
  const EnvelopeTooNewException(this.version);

  /// The version the sender used.
  final int version;

  @override
  String toString() =>
      'EnvelopeTooNewException: envelope v$version is newer than this build '
      '(max ${EnvelopeVersions.maxSupported}) — the app needs updating';
}

/// The stand-in stored for a message this build cannot open yet.
///
/// Shaped like the other `_chattr_*` envelopes so it travels through the same
/// paths: it is ordinary text as far as storage is concerned, and the chat
/// renders it as a card instead of showing raw JSON.
///
/// It carries the version so the notice can be specific, and so a later build
/// can tell at a glance what it was waiting for.
class UnsupportedEnvelopeNotice {
  static const String key = '_chattr_unsupported';

  const UnsupportedEnvelopeNotice(this.version);

  final int version;

  String encode() => jsonEncode({key: 1, 'v': version});

  /// Parses a stored notice, or null if [body] is not one.
  static UnsupportedEnvelopeNotice? tryParse(String? body) {
    if (body == null || !body.contains(key)) return null;
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      if (m[key] == null) return null;
      final v = m['v'];
      return UnsupportedEnvelopeNotice(v is int ? v : 0);
    } catch (_) {
      // Same legacy map notation as UndecryptableNotice: a stand-in for a
      // system message was stored as `{_chattr_unsupported: 1, v: 7}`.
      final legacy = _mapNotation.firstMatch(body.trim());
      return legacy == null
          ? null
          : UnsupportedEnvelopeNotice(int.parse(legacy.group(1)!));
    }
  }

  static final _mapNotation = RegExp(r'^\{_chattr_unsupported: 1, v: (\d+)\}$');
}
