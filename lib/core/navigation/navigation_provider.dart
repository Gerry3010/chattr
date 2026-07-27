// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'navigation_service.dart';

/// Provider for navigation service
final navigationServiceProvider = Provider<NavigationService>((ref) {
  return NavigationService();
});
