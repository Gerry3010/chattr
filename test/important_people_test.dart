// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// "Important" per person (1.26.2). The marking stays on the device — the server
// should not know which people mean the most to you. That makes the copy in the
// app group the ONLY way the iOS extension learns of it, and this test guards
// that above all: a flag that is set but was never mirrored looks in operation
// like "the feature can't do anything".

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/profiles/important_people_controller.dart';

const _anna = 'aaaaaaaa-1111-4111-8111-111111111111';
const _bert = 'bbbbbbbb-2222-4222-8222-222222222222';
const _key = 'important_people_v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Set<String>> gespiegelt;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    gespiegelt = [];
  });

  Future<ImportantPeopleController> loaded() async {
    final c = ImportantPeopleController(
      const FlutterSecureStorage(),
      mirror: (ids) async => gespiegelt.add(ids),
    );
    await Future<void>.delayed(Duration.zero);
    return c;
  }

  test('at first nobody is important', () async {
    final c = await loaded();
    expect(c.state, isEmpty);
    expect(c.isImportant(_anna), isFalse);
  });

  test('marking applies only to the person marked', () async {
    final c = await loaded();
    await c.set(_anna, important: true);

    expect(c.isImportant(_anna), isTrue);
    expect(c.isImportant(_bert), isFalse);
  });

  test('every change is mirrored into the app group', () async {
    final c = await loaded();
    await c.set(_anna, important: true);
    await c.set(_bert, important: true);
    await c.set(_anna, important: false);

    expect(gespiegelt, [
      {_anna},
      {_anna, _bert},
      {_bert},
    ]);
  });

  test('a change that changes nothing does not mirror either', () async {
    final c = await loaded();
    await c.set(_anna, important: false);
    expect(gespiegelt, isEmpty, reason: 'otherwise every tap writes');
  });

  test('toggling flips back and forth', () async {
    final c = await loaded();
    await c.toggle(_anna);
    expect(c.isImportant(_anna), isTrue);
    await c.toggle(_anna);
    expect(c.isImportant(_anna), isFalse);
  });

  test('the marking survives a restart', () async {
    await (await loaded()).set(_anna, important: true);
    gespiegelt = [];

    final neu = await loaded();
    expect(neu.isImportant(_anna), isTrue);
    // And the extension is re-supplied in the process: it keeps its own copy,
    // and a stale one would quietly demote a person.
    expect(gespiegelt, [
      {_anna}
    ]);
  });

  test('a broken store makes nobody important', () async {
    // The harmless direction: in doubt one notification too quiet, not a whole
    // list too loud.
    FlutterSecureStorage.setMockInitialValues({_key: 'kein json'});

    final c = await loaded();
    expect(c.state, isEmpty);
    expect(gespiegelt, isEmpty);
  });

  test('foreign entries in the store are sorted out', () async {
    FlutterSecureStorage.setMockInitialValues({
      _key: jsonEncode([_anna, 42, null]),
    });

    final c = await loaded();
    expect(c.state, {_anna});
  });
}
