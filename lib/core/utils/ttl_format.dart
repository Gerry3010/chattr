// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';

/// Human-readable label for a disappearing-messages TTL, e.g. "5 Minuten".
///
/// Lives in `core/` because two unrelated places need the exact same wording:
/// the chat-detail picker that sets the TTL, and the system message that
/// announces the change to every member. The announcement carries the raw
/// seconds over the wire (not a rendered string) so each device formats it in
/// its own locale.
/// The unit labels carry a singular form: the picker offers exactly one of each
/// unit, so a fixed plural read "1 Wochen" / "1 Stunden" — in the picker AND in
/// the announcement it generates.
String formatMessageTtl(int seconds) {
  if (seconds < 60) return _unit('ttl_seconds', seconds);
  if (seconds < 3600) return _unit('ttl_minutes', seconds ~/ 60);
  if (seconds < 86400) return _unit('ttl_hours', seconds ~/ 3600);
  if (seconds < 604800) return _unit('ttl_days', seconds ~/ 86400);
  return _unit('ttl_weeks', seconds ~/ 604800);
}

/// Picks the `one`/`other` form by hand rather than via easy_localization's
/// `.plural()`: that throws a LateInitializationError when no locale is loaded
/// yet, and a system message must never be able to take the app down over its
/// own wording. `.tr()` degrades to the key instead. `count == 1` is the right
/// rule for both shipped locales (de, en); a locale with a richer plural system
/// would need the real CLDR categories here.
String _unit(String key, int count) =>
    'chat_detail.$key.${count == 1 ? 'one' : 'other'}'.tr(args: ['$count']);
