// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Thrown by the send path when a chat has NO reachable recipient keys yet —
/// typically right after a QR-add, before the freshly-added peer's client has
/// registered its per-chat public key (#116).
///
/// This is a **transient** condition, NOT a failure: the peer registers its key
/// a moment after joining. Callers must treat it as "try again shortly" — keep
/// the composer text and surface a friendly hint — never as "message failed" or
/// a reason to drop the draft. It is deliberately a distinct type so the UI can
/// tell it apart from a real send error (auth, network, encryption).
class KeysNotReadyException implements Exception {
  final String message;

  const KeysNotReadyException([
    this.message =
        'Recipient encryption keys are not available yet — the peer is still '
            'registering its chat key.',
  ]);

  @override
  String toString() => 'KeysNotReadyException: $message';
}
