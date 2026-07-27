// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/security/security_providers.dart';
import 'chats_local_repository.dart';

/// Provider for chats local repository
final chatsLocalRepositoryProvider = Provider<ChatsLocalRepository>((ref) {
  final dbService = ref.read(databaseServiceProvider);
  final encryptionService = ref.read(encryptionServiceProvider);
  return ChatsLocalRepository(dbService, encryptionService);
});
