// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';
import 'mute_controller.dart';

/// Local-only "report" for an anonymous E2E app: the server holds only
/// ciphertext and there is no moderation backend, so a report is a private,
/// on-device record. Reporting a chat also mutes it. Kept deliberately simple;
/// a server-side abuse table can be layered on later if moderation is added.
final reportedChatsProvider =
    StateNotifierProvider<ReportController, Set<String>>((ref) {
  return ReportController(ref.read(secureStorageProvider), ref);
});

class ReportController extends StateNotifier<Set<String>> {
  static const _storageKey = 'reported_chats_v1';

  final FlutterSecureStorage _storage;
  final Ref _ref;

  ReportController(this._storage, this._ref) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null || !mounted) return;
    final list = (jsonDecode(raw) as List).cast<String>();
    state = list.toSet();
  }

  bool isReported(String chatId) => state.contains(chatId);

  /// Record a report and mute the chat.
  Future<void> report(String chatId) async {
    state = {...state, chatId};
    await _storage.write(key: _storageKey, value: jsonEncode(state.toList()));
    await _ref.read(mutedChatsProvider.notifier).mute(chatId);
  }
}
