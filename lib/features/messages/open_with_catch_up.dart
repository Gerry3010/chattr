// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

/// How long opening a chat waits for the server's catch-up before it shows
/// what the device already has. Online the catch-up is done in well under a
/// second.
const Duration catchUpGrace = Duration(milliseconds: 1500);

/// Opening a chat: catch up with the server, then show the local page, but
/// never let a silent server keep the chat empty (CHAT-63).
///
/// The order is not arbitrary. The unread divider and the jump to where
/// reading stopped are computed once, from the first batch on screen, so the
/// messages the catch-up brings must be in that batch. Until 2026-10-29 the
/// chat waited for the catch-up unconditionally, and offline that meant
/// waiting until the network stack gave up (gotrue's session-refresh retries
/// alone take ~12 s): the chat sat empty, although every message was on the
/// device (Gerry's Galaxy).
///
/// So the catch-up gets [grace]. If it is done by then, the local page shows
/// once, as before. If not, the local page shows now and again once the
/// catch-up has finished. [catchUp] must not throw; [mounted] is checked
/// before every step, because the chat may close while this waits.
Future<void> openWithCatchUp({
  required Future<void> Function() catchUp,
  required Future<void> Function() showLocal,
  required bool Function() mounted,
  Duration grace = catchUpGrace,
}) async {
  final pending = catchUp();
  final inTime = await pending
      .then((_) => true)
      .timeout(grace, onTimeout: () => false);
  if (!inTime) {
    if (!mounted()) return;
    await showLocal();
    if (!mounted()) return;
    await pending;
  }
  if (!mounted()) return;
  await showLocal();
}
