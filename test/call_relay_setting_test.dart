// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// "Route calls through the Chattr server" is ON unless the user said no.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/security/security_providers.dart';
import 'package:chattr/features/calls/call_relay_setting.dart';

Future<bool> _resolved(Map<String, String> stored) async {
  FlutterSecureStorage.setMockInitialValues(stored);
  final c = ProviderContainer(overrides: [
    secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
  ]);
  addTearDown(c.dispose);
  c.listen(callRelayOnlyProvider, (_, _) {});
  return c.read(callRelayOnlyProvider.notifier).resolvedValue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ohne gespeicherten Wert läuft der Anruf übers Relay', () async {
    expect(await _resolved({}), isTrue);
  });

  test('nur ein ausdrückliches false schaltet es ab', () async {
    expect(await _resolved({'call_relay_only_v1': 'false'}), isFalse);
    expect(await _resolved({'call_relay_only_v1': 'true'}), isTrue);
  });
}
