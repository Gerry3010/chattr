// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'media_attachment.dart';

/// A **shot**: a photo or video that can be opened exactly once and is gone
/// afterwards.
///
/// **Why an envelope of its own and not a field in the media envelope.** An
/// unknown field is silently ignored by every implementation — which is exactly
/// what is wanted for the length padding and the harm here: an older client
/// would show the shot as an ordinary photo, as often as one liked, and nobody
/// would notice the promise had been broken. So the attachment sits INSIDE,
/// under `a`, and the marker `_chattr_media` does not occur in the body:
/// `MediaAlbum.tryParse` checks for exactly that (`media_attachment.dart`) and
/// finds nothing here.
///
/// That is the second safeguard. The first is **envelope version 6**
/// (`envelope_version.dart`): whoever does not know it gets the "newer app
/// version needed" card and never sees the body at all.
///
/// **Consumed means empty.** After viewing, the local copy is replaced by
/// [consumed] — the same envelope without `a`. With it the **media key**
/// disappears, and that is the actual burn: the ciphertext in the server's
/// store may lie around for a few more hours, but nobody can unlock it after
/// that. A recipient would not be allowed to delete the file itself at all —
/// only whoever uploaded it may (`00016_media_sharing.sql`). It falls to the
/// existing sweeper once every recipient has confirmed the fetch (`00056`).
class ShotEnvelope {
  static const String marker = '_chattr_shot';

  /// Photo or video — still stated even when the attachment is already gone, so
  /// the consumed bubble keeps carrying the right colour and the right icon.
  final MediaType kind;

  /// The attachment, or `null` when the shot is consumed.
  final MediaAttachment? attachment;

  const ShotEnvelope({required this.kind, this.attachment});

  /// Builds the envelope around a freshly uploaded attachment.
  factory ShotEnvelope.of(MediaAttachment attachment) =>
      ShotEnvelope(kind: attachment.mediaType, attachment: attachment);

  /// Nichts mehr zu oeffnen — angesehen, abgelaufen oder nie angekommen.
  bool get isConsumed => attachment == null;

  /// The same bubble without content. That is the burn.
  ShotEnvelope consumed() => ShotEnvelope(kind: kind);

  String encode() => jsonEncode({
        marker: 1,
        'kind': kind.name,
        if (attachment != null) 'a': attachment!.toItemJson(),
      });

  static ShotEnvelope? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final a = json['a'];
      return ShotEnvelope(
        kind: MediaType.fromName((json['kind'] as String?) ?? 'image'),
        // An unreadable attachment is like no attachment: the bubble stands, it
        // just cannot be opened any more. That is the safe direction — a half-
        // parsed shot that can be opened after all would be the other one.
        attachment: a is Map<String, dynamic>
            ? _attachmentOrNull(a)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static MediaAttachment? _attachmentOrNull(Map<String, dynamic> json) {
    try {
      return MediaAttachment.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}

/// Is this message body a shot? Short form for the many places that only need
/// "yes/no" (locking actions, replacing previews).
bool isShotMessage(String? body) => ShotEnvelope.tryParse(body) != null;

/// How long the bubble stays after opening.
///
/// The content is gone at once — this is only about the remainder: the badge in
/// the history. It stays for a day, so the sender can still look at what they
/// sent, and after that it disappears on **both** sides. A permanently standing
/// "opened" mark would be a trace that outlives the point of the thing.
const Duration kShotAfterlife = Duration(hours: 24);

/// When a shot's bubble disappears — `null` when it is not one or has not been
/// opened yet.
///
/// **One rule for both sides**, which is why it hangs on the read mark: at the
/// recipient it is set on opening (not already on seeing the bubble — a shot
/// only counts as read once it has actually been viewed), at the sender it
/// arrives as a read receipt. Both clocks therefore show the same moment.
///
/// The honest flip side: whoever has read receipts switched off sends none here
/// either — their counterpart permanently sees "not opened yet", and their copy
/// does not expire. That is the consistent continuation of the same setting; an
/// opening notice that could not be switched off would be a side channel around
/// it.
DateTime? shotDisappearsAt(String? body, Map<String, DateTime?> readAt) {
  if (ShotEnvelope.tryParse(body) == null) return null;
  DateTime? frueheste;
  for (final t in readAt.values) {
    if (t == null) continue;
    if (frueheste == null || t.isBefore(frueheste)) frueheste = t;
  }
  return frueheste?.add(kShotAfterlife);
}
