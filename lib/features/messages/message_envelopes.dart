// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../../core/crypto/envelope_version.dart';
import '../invites/invite_envelope.dart';
import '../media/shot_envelope.dart';
import '../places/place_envelope.dart';
import '../../core/crypto/undecryptable_notice.dart';

/// Is this message body a structured envelope rather than something a person
/// wrote — an invitation, a shared place, a calendar entry?
///
/// These render as cards but travel as JSON in a plain text message, so every
/// text-shaped action applies to them by default. Two of those must not:
/// **Edit** would open the box with `{"_chattr_event":1,…}` and saving it would
/// break the card for every recipient, and **Copy** would put the same JSON on
/// the clipboard. There is no meaningful edit for a pin someone dropped, so the
/// action disappears instead of being repaired (Gerry, 2026-08-13).
///
/// Reply and Forward deliberately stay available — passing a place or an
/// invitation on is exactly what they are for.
///
/// Media is NOT included: it has its own envelope and its own action rules
/// (a caption is editable prose).
///
/// The stand-in for a not-yet-readable message counts too: it is not the
/// message, so there is nothing there worth copying, editing or forwarding —
/// passing it on would hand someone else a placeholder.
bool isEnvelopeMessage(String? body) =>
    InviteEnvelope.tryParse(body) != null ||
    LocationEnvelope.tryParse(body) != null ||
    EventEnvelope.tryParse(body) != null ||
    UnsupportedEnvelopeNotice.tryParse(body) != null ||
    UndecryptableNotice.tryParse(body) != null ||
    // A shot counts among them: copying would put path and media key on the
    // clipboard, editing would shred the envelope.
    isShotMessage(body);
