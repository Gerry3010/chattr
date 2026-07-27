// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/security/security_providers.dart';
import 'messages_local_repository.dart';

/// Provider for messages local repository
final messagesLocalRepositoryProvider =
    Provider<MessagesLocalRepository>((ref) {
  final dbService = ref.read(databaseServiceProvider);
  final encryptionService = ref.read(encryptionServiceProvider);
  return MessagesLocalRepository(dbService, encryptionService);
});
