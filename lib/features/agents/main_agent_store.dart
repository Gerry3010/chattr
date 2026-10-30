// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// The chat's chosen MAIN agent — exactly one per chat, by decree.
///
/// A chat can contain several agent members, but features that address "the
/// agent" (the chat summary, and later anything else that talks to one) need a
/// single deterministic target, or every agent answers at once. This store
/// holds that choice.
///
/// Deliberately LOCAL-ONLY (secure storage, per device): the choice is a UI
/// preference of this user on this device, not chat state the other members
/// need to agree on. Server-side storage only becomes necessary once multiple
/// devices per account exist — losing the choice on reinstall merely falls
/// back to "any agent may answer", which is the correct degraded behaviour.
final mainAgentProvider = StateNotifierProvider.family<MainAgentController,
    String?, String>((ref, chatId) {
  return MainAgentController(ref.read(secureStorageProvider), chatId);
});

class MainAgentController extends StateNotifier<String?> {
  static String _key(String chatId) => 'main_agent_v1_$chatId';

  final FlutterSecureStorage _storage;
  final String chatId;

  MainAgentController(this._storage, this.chatId) : super(null) {
    _init();
  }

  Future<void> _init() async {
    try {
      final raw = await _storage.read(key: _key(chatId));
      if (mounted && raw != null && raw.isNotEmpty) state = raw;
    } catch (_) {
      // Unreadable storage degrades to "no main agent chosen" — safe.
    }
  }

  /// Sets (or with null clears) the main agent for this chat.
  Future<void> set(String? userId) async {
    if (userId == null || userId.isEmpty) {
      await _storage.delete(key: _key(chatId));
      state = null;
    } else {
      await _storage.write(key: _key(chatId), value: userId);
      state = userId;
    }
  }
}
