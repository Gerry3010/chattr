// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../supabase/supabase_client_provider.dart';
import '../../features/auth/auth_controller.dart';
import 'event_bus_service.dart';

/// Provider for the central event bus
/// 
/// Returns null if user is not logged in
final eventBusProvider = Provider<EventBusService?>((ref) {
  final client = ref.read(supabaseClientProvider);
  final userId = ref.watch(authControllerProvider);

  if (userId == null) {
    return null;
  }

  final eventBus = EventBusService(client, userId);
  
  // Subscribe on creation
  eventBus.subscribe();

  // Cleanup on dispose
  ref.onDispose(() {
    eventBus.dispose();
  });

  return eventBus;
});
