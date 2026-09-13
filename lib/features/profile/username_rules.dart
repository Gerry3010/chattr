// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// How long a username may be.
///
/// **Why this is a constant and not a number in the widget.** The limit used to
/// stand only in the rename field (`settings_screen.dart`, `maxLength: 40`) —
/// in the creation field on the sign-in screen there was nothing at all. That
/// is the worse half: that is where the name comes into being. On 2026-08-29 a
/// device created an account through it with a **5469 character** name (a
/// pasted documentation page). A number in two places drifts; a constant does
/// not.
///
/// The same number stands as a `CHECK` in the database (migration 00083) — the
/// UI is the convenience, the database the guarantee.
const int kMaxUsernameLength = 40;

/// Is this name acceptable? Empty (including only spaces) is not, too long is
/// not either.
bool isValidUsername(String name) {
  final trimmed = name.trim();
  return trimmed.isNotEmpty && trimmed.runeLength <= kMaxUsernameLength;
}

extension on String {
  /// Measure in characters, not in code units: a name made of emoji or of
  /// letters outside the basic plane otherwise counts double in Dart, and the
  /// limit would bite differently depending on the alphabet.
  int get runeLength => runes.length;
}
