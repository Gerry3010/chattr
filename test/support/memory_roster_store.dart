// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/chats/roster_store.dart';
import 'package:chattr/features/profiles/profile_model.dart';

/// A [RosterStore] in memory, for tests.
class MemoryRosterStore implements RosterStore {
  final Map<String, List<String>> members = {};
  final Map<String, Profile> profiles = {};

  @override
  Future<Map<String, List<String>>> loadMembers() async => {...members};

  @override
  Future<void> saveMembers(String chatId, List<String> memberIds) async =>
      members[chatId] = [...memberIds];

  @override
  Future<void> deleteMembers(String chatId) async => members.remove(chatId);

  @override
  Future<Map<String, Profile>> loadProfiles() async => {...profiles};

  @override
  Future<void> saveProfiles(Iterable<Profile> list) async {
    for (final p in list) {
      if (p.exists) profiles[p.id] = p;
    }
  }

  @override
  Future<void> deleteProfiles(Iterable<String> userIds) async {
    for (final id in userIds) {
      profiles.remove(id);
    }
  }

  @override
  Future<void> clearAll() async {
    members.clear();
    profiles.clear();
  }
}
