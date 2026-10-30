// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../media/shot_envelope.dart';
import 'message_model.dart';

/// When a message disappears by itself — **one rule for two passes**.
///
/// There are two clocks doing the same thing:
///
/// * the **self-destruct** (`expiresAt`, configurable per chat), and
/// * the **afterlife of an opened shot** (24 hours from the read mark, see
///   [shotDisappearsAt]) — the content has long since burned there, this is only
///   about the badge in the history.
///
/// And there are two places that clear up: the full pass when the chat is opened
/// (which also goes through the local database) and the five-second tick that
/// pushes already loaded messages out of the running view, so that a self-destruct
/// happens **live** and not only on the next entry.
///
/// That is exactly where the fault lay (found 2026-08-28, fixed in 1.27.1): the
/// tick only checked `expiresAt`. A shot therefore expired only when the chat was
/// entered again — if one was sitting inside it, the bubble stayed put. No leak,
/// the content was gone; but not what the code appeared to promise.
///
/// So from here on the question "is this due now?" stands **once** here and not
/// twice side by side.
DateTime? messageGoesAt(Message m) {
  final shot = shotDisappearsAt(m.decryptedContent, m.readAt);
  final ttl = m.expiresAt;
  if (shot == null) return ttl;
  if (ttl == null) return shot;
  // Whatever falls due first wins — a shot in a chat with self-destruct does
  // not disappear later than the rest.
  return shot.isBefore(ttl) ? shot : ttl;
}

/// Is [m] due at time [now]?
bool messageIsGone(Message m, DateTime now) {
  final t = messageGoesAt(m);
  return t != null && t.isBefore(now);
}
