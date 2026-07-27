// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'in_app_notification_service.dart';

/// Provider for the in-app notification service
final inAppNotificationServiceProvider = Provider<InAppNotificationService>((ref) {
  final service = InAppNotificationService();
  
  // Cleanup when provider is disposed
  ref.onDispose(() {
    service.dispose();
  });
  
  return service;
});
