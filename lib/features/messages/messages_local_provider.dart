// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'messages_local_repository.dart';

/// Provider for messages local repository
final messagesLocalRepositoryProvider =
    Provider<MessagesLocalRepository>((ref) {
  final dbService = ref.read(databaseServiceProvider);
  final encryptionService = ref.read(encryptionServiceProvider);
  final client = ref.read(supabaseClientProvider);
  return MessagesLocalRepository(
    dbService,
    encryptionService,
    // Resolved per call, not captured: the repository outlives a sign-out.
    () => client.auth.currentUser?.id,
  );
});
