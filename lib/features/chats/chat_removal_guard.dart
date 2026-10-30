// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging/logger_service.dart';

/// The brake in front of the chat reconcile (CHAT-32).
///
/// `refreshChats` treats a chat missing from a successful fetch as deleted or
/// left, and removing it locally deletes every message in it. The local
/// database is the only readable copy of read messages, so that deletion cannot
/// be undone. Until 2026-10 the only brake was the two-minute create grace:
/// a server that answered successfully with no chats (a broken RPC or
/// migration, an RLS regression) would have wiped the history of the whole
/// fleet on the next resume. `account_gone_guard.dart` brakes the same class of
/// failure for `user_not_found`; this is its counterpart for chats.
///
/// **What counts as suspicious.** One chat vanishing is the normal case: the
/// peer deleted it for everyone while we were offline and missed the event.
/// Many vanishing at once is what a server fault looks like. So a removal is
/// held when a full fetch came back empty, or when it would take at least
/// [kMassRemovalMin] chats AND at least half of the established ones.
///
/// **What happens to a held chat.** It stays, readable as before, and is
/// removed only once the server has said the same thing over
/// [kChatRemovalGrace] and at least [kChatRemovalMinFetches] fetches; the same
/// two conditions as the account grace, for the same reasons. One fetch that
/// returns it again forgets the record.
///
/// The price, openly: a user whose one remaining chat was deleted while they
/// were offline sees it for three more days. Paid against losing every chat
/// to one bad deploy.
class MissingChatRecord {
  /// When a suspicious fetch first left the chat out.
  final DateTime firstSeen;

  /// How many suspicious fetches have left it out since.
  final int fetches;

  const MissingChatRecord({required this.firstSeen, required this.fetches});

  Map<String, dynamic> toJson() => {
        'first_seen': firstSeen.toUtc().toIso8601String(),
        'fetches': fetches,
      };

  static MissingChatRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ts = DateTime.tryParse(raw['first_seen'] as String? ?? '');
    final n = raw['fetches'];
    if (ts == null || n is! int || n < 0) return null;
    return MissingChatRecord(firstSeen: ts.toUtc(), fetches: n);
  }

  @override
  bool operator ==(Object other) =>
      other is MissingChatRecord &&
      other.firstSeen == firstSeen &&
      other.fetches == fetches;

  @override
  int get hashCode => Object.hash(firstSeen, fetches);
}

/// Three days, like the account grace: long enough for a broken deploy to be
/// noticed and restored from the pre-deploy backup.
const Duration kChatRemovalGrace = Duration(hours: 72);

/// Time alone would let a device that slept in a drawer delete on its first
/// fetch after waking up; it has to be asked repeatedly as well.
const int kChatRemovalMinFetches = 3;

/// Below this, a removal is never "mass": two chats is the smallest number
/// that can be a pattern rather than one deletion.
const int kMassRemovalMin = 2;

/// Does this fetch look like a server fault rather than ordinary deletions?
///
/// [established] counts the local chats old enough to be candidates at all
/// (past the create grace). A targeted fetch ([fullFetch] false) asked for a
/// few ids and returning none of them is normal; only the share rule applies.
bool looksLikeMassRemoval({
  required int removed,
  required int established,
  required bool fullFetch,
  required int fetched,
}) {
  if (removed == 0) return false;
  if (fullFetch && fetched == 0) return true;
  return removed >= kMassRemovalMin && removed * 2 >= established;
}

/// What the reconcile may do now.
class ChatRemovalPlan {
  /// Delete locally now.
  final List<String> remove;

  /// Missing on the server, but kept until the grace runs out.
  final List<String> hold;

  /// The records to store afterwards.
  final Map<String, MissingChatRecord> records;

  const ChatRemovalPlan({
    required this.remove,
    required this.hold,
    required this.records,
  });
}

/// The decision, pure: no storage, no network.
///
/// [candidates] are what `computeRemovedChatIds` found missing. [presentIds]
/// are the chats the fetch returned (their records are forgotten), [localIds]
/// every chat on the device (records for chats gone otherwise are pruned).
ChatRemovalPlan planChatRemovals({
  required List<String> candidates,
  required Set<String> presentIds,
  required Set<String> localIds,
  required Map<String, MissingChatRecord> records,
  required bool suspicious,
  required DateTime now,
  Duration grace = kChatRemovalGrace,
  int minFetches = kChatRemovalMinFetches,
}) {
  final next = <String, MissingChatRecord>{
    for (final e in records.entries)
      if (localIds.contains(e.key) && !presentIds.contains(e.key)) e.key: e.value,
  };
  final remove = <String>[];
  final hold = <String>[];
  for (final id in candidates) {
    if (!suspicious) {
      remove.add(id);
      next.remove(id);
      continue;
    }
    final before = next[id];
    final record = MissingChatRecord(
      firstSeen: before?.firstSeen ?? now.toUtc(),
      fetches: (before?.fetches ?? 0) + 1,
    );
    final due = record.fetches >= minFetches &&
        !now.toUtc().isBefore(record.firstSeen.add(grace));
    if (due) {
      remove.add(id);
      next.remove(id);
    } else {
      hold.add(id);
      next[id] = record;
    }
  }
  return ChatRemovalPlan(remove: remove, hold: hold, records: next);
}

/// Where the records live between fetches. Plain SharedPreferences: chat ids
/// are in the local database anyway, and a lost store only restarts the grace,
/// which errs on the side of keeping.
class ChatRemovalStore {
  static const _key = 'chat_removal_pending_v1';

  Future<Map<String, MissingChatRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          e.key as String: ?MissingChatRecord.fromJson(e.value),
      };
    } catch (e) {
      // Unreadable means "nothing held so far", never "delete".
      logger.warning('Could not read held chat removals: $e',
          tag: 'ChatsController');
      return {};
    }
  }

  Future<void> save(Map<String, MissingChatRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (records.isEmpty) {
        await prefs.remove(_key);
        return;
      }
      await prefs.setString(
        _key,
        jsonEncode({for (final e in records.entries) e.key: e.value.toJson()}),
      );
    } catch (e) {
      logger.warning('Could not store held chat removals: $e',
          tag: 'ChatsController');
    }
  }
}

final chatRemovalStoreProvider =
    Provider<ChatRemovalStore>((_) => ChatRemovalStore());
