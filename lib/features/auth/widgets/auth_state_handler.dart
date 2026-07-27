// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../auth_controller.dart';
import '../../../core/notifications/notification_controller.dart';
import '../../messages/system_message_controller.dart';
import '../../../screens/screens.dart';

/// Zeigt Login oder Chat-Screen basierend auf Auth-Status
class AuthStateHandler extends ConsumerWidget {
  const AuthStateHandler({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(authControllerProvider);

    // Initialize controllers when user is logged in
    if (userId != null) {
      ref.watch(notificationControllerProvider);
      ref.watch(systemMessageControllerProvider);
    }

    // Zeige Login-Screen wenn nicht angemeldet
    if (userId == null) {
      return const LoginScreen();
    }

    // Zeige Chat-Liste wenn angemeldet
    return const ChatListScreen();
  }
}
