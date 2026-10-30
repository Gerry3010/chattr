// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What a scanned QR code may do to the pin of the person it shows (CHAT-42).
enum QrPinDecision { pinVerified, mismatch }

/// Scanning in person is the strong channel, but it used to pin the code's key
/// as verified without looking further: an existing, different pin was
/// overwritten silently, and a code that disagreed with the key the server
/// publishes for that person turned green. A forged code plus a lying server
/// would have produced a verified man in the middle.
///
/// Now the code verifies only when it agrees with what is published, or, if
/// nothing could be fetched (offline), with what was pinned before. Every
/// disagreement is shown, never resolved quietly in either direction.
QrPinDecision decideQrPin({
  required String scanned,
  required String? published,
  required String? pinned,
}) {
  if (published != null && published.isNotEmpty) {
    return published == scanned
        ? QrPinDecision.pinVerified
        : QrPinDecision.mismatch;
  }
  if (pinned == null || pinned == scanned) return QrPinDecision.pinVerified;
  return QrPinDecision.mismatch;
}
