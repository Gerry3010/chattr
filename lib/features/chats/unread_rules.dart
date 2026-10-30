// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// When an arriving message may raise a chat's unread badge.
///
/// Pulled out of `GlobalMessageHandler` because the rule grew a third condition
/// and every one of them is a bug someone already hit:
///
/// * **[isNew]** — a re-delivered message (catch-up after a reconnect) must not
///   bump anything. It was counted the first time.
/// * **[senderId] vs [currentUserId]** — your own message is not unread. On a
///   second device it arrives like any other, so this cannot be assumed away.
/// * **[activeChatId]** — a message landing in the chat you are LOOKING AT is
///   read on arrival. Before this, it bumped the badge and the open chat raced
///   to clear it again; when the race was lost the chat you had just read kept
///   its badge ("manchmal", reported 2026-08-05).
///
/// A pure function so the rule can be stated once and tested, rather than being
/// re-derived from an `&&` chain in a file about decryption.
bool shouldBumpUnread({
  required bool isNew,
  required String? senderId,
  required String? currentUserId,
  required String chatId,
  required String? activeChatId,
}) {
  if (!isNew) return false;
  // A null senderId is a system message (edge function author) — nobody's own,
  // so it counts, subject to the checks below.
  if (senderId != null && currentUserId != null && senderId == currentUserId) {
    return false;
  }
  if (activeChatId == chatId) return false;
  return true;
}

/// Where a chat's read marker goes when the chat is opened.
///
/// [newestLocal] is the `created_at` of the newest message the device actually
/// holds; [current] is the marker already stored.
///
/// The obvious answer — `DateTime.now()` — is wrong, and was the shipped one.
/// The count compares a message's `created_at`, a SERVER timestamp, against
/// this marker. Stamping the device clock puts the marker ahead of messages
/// that exist on the server but have not reached the device yet: when one of
/// them lands, it is older than the marker and never counted, while its own
/// `readAt` is still null so the open chat correctly draws an "Ungelesene
/// Nachrichten" divider over it. Badge missing, divider present — reported by
/// Gerry 2026-08-12, and "manchmal" because it needs a message in flight at the
/// moment the chat is opened.
///
/// Anchoring to a message that is really here removes the second clock from the
/// comparison entirely. The marker also never moves backwards: a disappearing
/// message expiring would otherwise lower the maximum and resurrect the badge
/// on everything older than it.
DateTime? readMarkerFor({
  required DateTime? current,
  required DateTime? newestLocal,
}) {
  if (newestLocal == null) return current;
  if (current == null || newestLocal.isAfter(current)) return newestLocal;
  return current;
}
