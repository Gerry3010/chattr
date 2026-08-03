// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'typing_indicator_service.dart';

/// Provider for TypingIndicatorService
final typingIndicatorServiceProvider = Provider<TypingIndicatorService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final service = TypingIndicatorService(supabase);
  
  ref.onDispose(() {
    service.dispose();
  });
  
  return service;
});

/// Provider for typing indicators stream for a specific chat
final typingIndicatorsProvider = StreamProvider.family<List<String>, String>(
  (ref, chatId) {
    final service = ref.watch(typingIndicatorServiceProvider);
    return service.subscribeToTypingIndicators(chatId);
  },
);
