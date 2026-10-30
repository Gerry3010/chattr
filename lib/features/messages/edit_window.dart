// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// How long a sent message may still be edited (Gerry, 2026-10-05).
///
/// Unread: up to a day after sending. Once someone has read it: up to ten
/// minutes after that FIRST read — a correction long after somebody read
/// and maybe answered would change what they answered to. Never later than
/// a day after sending. The server enforces the same rule (`edit_message`,
/// 00090); this copy only decides whether to OFFER the edit.
///
/// "Read" is what this device knows. With read receipts off it knows
/// nothing and offers the longer window; if the server knows better, it
/// refuses and the user gets told why.
const Duration editWindowUnread = Duration(hours: 24);
const Duration editWindowAfterRead = Duration(minutes: 10);

/// The moment editing ends.
DateTime editDeadline({required DateTime sentAt, DateTime? firstReadAt}) {
  final day = sentAt.add(editWindowUnread);
  if (firstReadAt == null) return day;
  final afterRead = firstReadAt.add(editWindowAfterRead);
  return afterRead.isBefore(day) ? afterRead : day;
}

bool canEditMessage({
  required DateTime sentAt,
  DateTime? firstReadAt,
  required DateTime now,
}) {
  // Clock skew between devices must never lock the sender out early.
  if (now.isBefore(sentAt)) return true;
  return !now.isAfter(editDeadline(sentAt: sentAt, firstReadAt: firstReadAt));
}

/// The earliest read time across recipients, or null if nobody has read
/// it (as far as this device knows).
DateTime? firstReadOf(Map<String, DateTime?> readAt) {
  DateTime? first;
  for (final t in readAt.values) {
    if (t != null && (first == null || t.isBefore(first))) first = t;
  }
  return first;
}
