// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// #107a hardening: the SEND gate must use the PERSISTED read-receipt pref, not
// the synchronous `true` default. resolvedValue() awaits the secure-storage
// load — so a cold start can't leak a read receipt when the user has them off.

import 'package:chattr/features/read_receipts/read_receipts_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Intercepts every call via noSuchMethod so we don't have to match the exact
/// FlutterSecureStorage signature; `read` returns the seeded value.
class _FakeSecureStorage implements FlutterSecureStorage {
  final String? stored;
  _FakeSecureStorage(this.stored);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(stored);
    if (invocation.memberName == #write) return Future<void>.value();
    throw UnimplementedError('${invocation.memberName}');
  }
}

void main() {
  test('resolvedValue awaits and returns the persisted OFF value (no default leak)',
      () async {
    final c = ReadReceiptsController(_FakeSecureStorage('false'));
    expect(await c.resolvedValue(), isFalse); // NOT the true default
  });

  test('resolvedValue returns true when stored true or absent', () async {
    expect(await ReadReceiptsController(_FakeSecureStorage('true')).resolvedValue(),
        isTrue);
    expect(await ReadReceiptsController(_FakeSecureStorage(null)).resolvedValue(),
        isTrue);
  });
}
