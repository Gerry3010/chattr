// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';

/// Placeholder controller for system messages.
///
/// System messages are now created directly in Supabase triggers via the
/// `insert_system_message()` function; this controller is kept for potential
/// future client-side system-message handling.
class SystemMessageController {
  SystemMessageController();
}

/// Provider for system message controller
final systemMessageControllerProvider = Provider<SystemMessageController?>((ref) {
  final userId = ref.watch(authControllerProvider);

  // Only initialize if user is logged in
  if (userId == null) {
    // throw StateError('System message controller requires authenticated user');
    return null;
  }

  // final systemMessageService = ref.watch(systemMessageServiceProvider);

  return SystemMessageController();
});
