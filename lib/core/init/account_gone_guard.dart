// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging/logger_service.dart';

/// The brake in front of the only remaining self-deletion path.
///
/// **What is at stake here.** The server clears the ciphertext away as soon as
/// the device has fetched it. The local database is thereby the **only**
/// readable copy of all read messages — what is deleted here cannot be restored
/// anywhere, not even from a server backup.
///
/// Deletion therefore only happens on a judgement the server passes
/// **repeatedly over days**. A single `user_not_found` no longer suffices.
///
/// **Why time is the right discriminator** (Gerry, 2026-08-31: "a maintenance
/// mode where the devices do not delete themselves even if their user were
/// deleted by a bug"). Both cases look the same at first: a genuine account
/// deletion and a broken migration both say "this user does not exist". They
/// differ only in their duration. A server fault is noticed and rolled back —
/// which is exactly what the pipeline has been backing up the database before
/// every server deploy for since 2026-08-31. An account deletion stays. Letting
/// time pass costs nothing and separates the two more reliably than any
/// heuristic in the moment itself.
///
/// **What the grace period does NOT loosen.** Without a valid session the app
/// shows no content — it lands on the sign-in screen. So the data is there, but
/// nobody sees it. The grace period delays the *destruction*, not the locking.
///
/// The price, openly stated: after a genuine remote deletion (account deleted
/// from another device) the old data stays on the device until the grace period
/// runs out, instead of being gone at once. As long as the local database is
/// not encrypted (#119) that is a real, if small, price — paid against a fleet-
/// wide, irreversible total loss.
class AccountGoneRecord {
  /// When the server FIRST declared the account non-existent.
  final DateTime firstSeen;

  /// Bei wie vielen App-Starts seither dasselbe Urteil kam.
  final int launches;

  const AccountGoneRecord({required this.firstSeen, required this.launches});

  Map<String, dynamic> toJson() => {
        'first_seen': firstSeen.toUtc().toIso8601String(),
        'launches': launches,
      };

  static AccountGoneRecord? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.tryParse(m['first_seen'] as String? ?? '');
      final n = m['launches'];
      if (ts == null || n is! int || n < 0) return null;
      return AccountGoneRecord(firstSeen: ts.toUtc(), launches: n);
    } catch (_) {
      // Unreadable means "we know nothing", not "delete". A broken entry must
      // never be the sharp side of the decision.
      return null;
    }
  }
}

/// How long the judgement has to stand before anything is deleted.
///
/// Three days are long enough for a broken deploy to be noticed and restored
/// from the pipeline backup, and short enough that a genuine remote deletion
/// does not stay ineffective for weeks.
const Duration kAccountGoneGrace = Duration(hours: 72);

/// How many launches the judgement has to survive at least.
///
/// **Why on top of the time.** Time alone would let a device that had lain in a
/// drawer for three months delete immediately on its first launch — the server
/// had after all been right "long enough", although it had only been asked
/// once. Launches alone would let three quick restarts in the middle of an
/// incident suffice. Only both together mean: asked repeatedly AND over a span
/// of time.
const int kAccountGoneMinLaunches = 3;

/// Is the judgement final? **A pure function** — no storage, no network, so the
/// rule is testable without rebuilding it.
bool accountGoneIsFinal(
  AccountGoneRecord? record,
  DateTime now, {
  Duration grace = kAccountGoneGrace,
  int minLaunches = kAccountGoneMinLaunches,
}) {
  if (record == null) return false;
  if (record.launches < minLaunches) return false;
  return !now.toUtc().isBefore(record.firstSeen.add(grace));
}

/// The key in secure storage. `_v1`, so a later change of shape does not
/// misinterpret an old entry.
const String kAccountGoneStorageKey = 'account_gone_v1';

/// Records that the server has (again) declared the account non-existent, and
/// returns the updated state.
Future<AccountGoneRecord> recordAccountGone(
  FlutterSecureStorage storage,
  DateTime now,
) async {
  final before = AccountGoneRecord.tryParse(
    await storage.read(key: kAccountGoneStorageKey),
  );
  final neu = AccountGoneRecord(
    firstSeen: before?.firstSeen ?? now.toUtc(),
    launches: (before?.launches ?? 0) + 1,
  );
  await storage.write(
    key: kAccountGoneStorageKey,
    value: jsonEncode(neu.toJson()),
  );
  logger.warning(
    'Server meldet das Konto als nicht existent (Start ${neu.launches}, '
    'erstmals ${neu.firstSeen.toIso8601String()}) — es wird NICHT geloescht, '
    'solange die Karenz laeuft.',
    tag: 'AccountGone',
  );
  return neu;
}

/// Forgets the judgement. Called as soon as a session is valid again — then it
/// was a blip, and the counter must not stay put and later tear through the
/// threshold with a second blip.
Future<void> clearAccountGone(FlutterSecureStorage storage) async {
  try {
    await storage.delete(key: kAccountGoneStorageKey);
  } catch (e) {
    logger.warning('Konnte den Konto-weg-Vermerk nicht loeschen: $e',
        tag: 'AccountGone');
  }
}
