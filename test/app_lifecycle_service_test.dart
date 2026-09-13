// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Unit tests for the resume signal that drives on-foreground resync
// (reconnect realtime + re-fetch missed messages / unread counts).
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/lifecycle/app_lifecycle_service.dart';

void main() {
  test('notifyResumed emits on onResume', () async {
    final service = AppLifecycleService();
    addTearDown(service.dispose);

    final future = service.onResume.first;
    service.notifyResumed();
    await expectLater(future, completes);
  });

  test('multiple listeners all receive the resume signal', () async {
    final service = AppLifecycleService();
    addTearDown(service.dispose);

    var a = 0, b = 0;
    service.onResume.listen((_) => a++);
    service.onResume.listen((_) => b++);

    service.notifyResumed();
    service.notifyResumed();
    // Let the broadcast stream deliver.
    await Future<void>.delayed(Duration.zero);

    expect(a, 2);
    expect(b, 2);
  });

  test('notifyResumed after dispose is a no-op (no throw)', () async {
    final service = AppLifecycleService();
    service.dispose();
    expect(service.notifyResumed, returnsNormally);
  });
}
