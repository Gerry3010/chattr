// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRepository {
  final SupabaseClient _client;

  AuthRepository(this._client);

  Future<void> signInAnonymously() async {
    await _client.auth.signInAnonymously();
  }

  Future<void> signOut() async {
    await _client.auth.signOut(scope: SignOutScope.global);
  }

  /// Delete the account server-side (anonymous accounts have no recovery, so
  /// logout == deletion). Must run while the session JWT is still valid,
  /// i.e. BEFORE [signOut]. Removes profile, memberships, messages and the
  /// auth user via the `delete-account` Edge Function.
  Future<void> deleteAccount() async {
    final response = await _client.functions.invoke('delete-account');
    if (response.status != 200) {
      throw Exception('delete-account failed (HTTP ${response.status})');
    }
  }

  String? get userId => _client.auth.currentUser?.id;
}
