// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'call_rules.dart';

/// Call entries in the chat ("Ausgehender Anruf · 2:13", "Verpasster Anruf").
///
/// They are LOCAL ONLY: each device writes its own entry into its own
/// encrypted database, and nothing about the call reaches the server as a
/// message. The server never knew how long two people talked — the entry
/// keeps it that way.
const String callOutgoing = 'call_outgoing';
const String callIncoming = 'call_incoming';
const String callMissed = 'call_missed';
const String callDeclined = 'call_declined';

const Set<String> callLogActions = {
  callOutgoing,
  callIncoming,
  callMissed,
  callDeclined,
};

/// One call entry: the system-message action, and in [detail] either the
/// talk time in whole seconds or, for an unanswered outgoing call, `'0'`.
class CallLogEntry {
  const CallLogEntry(this.action, this.detail);
  final String action;
  final String detail;
}

/// What a finished call leaves in the chat, or null for nothing.
///
/// Nothing for calls that never rang anywhere — no microphone, a peer whose
/// app can't take calls, a refused key, no relay: those failed on this
/// device, and a chat line saying "call" would claim a call that never
/// happened.
CallLogEntry? callLogEntryFor({
  required bool incoming,
  required CallEndReason reason,
  DateTime? connectedAt,
  required DateTime endedAt,
}) {
  switch (reason) {
    case CallEndReason.unavailable:
    case CallEndReason.keyChanged:
    case CallEndReason.micDenied:
    case CallEndReason.relayUnavailable:
      return null;
    default:
      break;
  }
  if (connectedAt != null) {
    final seconds = endedAt.difference(connectedAt).inSeconds;
    return CallLogEntry(
      incoming ? callIncoming : callOutgoing,
      '${seconds < 0 ? 0 : seconds}',
    );
  }
  if (incoming) {
    // We said no ourselves — not "missed", we saw it.
    if (reason == CallEndReason.declined) {
      return const CallLogEntry(callDeclined, '0');
    }
    return const CallLogEntry(callMissed, '0');
  }
  // Rang out on our side without being answered.
  return const CallLogEntry(callOutgoing, '0');
}

/// "2:13", "1:02:05".
String formatTalkTime(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}
