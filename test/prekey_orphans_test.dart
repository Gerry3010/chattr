// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// After a recovery on a new device the server still held ~94 unconsumed
// prekeys of the OLD installation. claim_prekey hands out the oldest first, so
// every v5 message to the new device was wrapped to a key it never had
// ("prekey … unavailable"), and replenishIfLow counted the pool as full and
// never published fresh prekeys. These tests pin the cleanup: prekeys on the
// server without a local private half are deleted before counting.

import 'package:chattr/core/security/kem_key_signer.dart';
import 'package:chattr/core/security/prekey_manager.dart';
import 'package:chattr/features/prekeys/prekey_local_repository.dart';
import 'package:chattr/features/prekeys/prekey_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRemote implements PrekeyRepository {
  _FakeRemote(this.onServer);
  final List<String> onServer;
  final List<List<String>> deleted = [];
  int publishes = 0;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Future<List<String>> unconsumedIds({
    required String chatId,
    required String userId,
  }) async =>
      List.of(onServer);

  @override
  Future<void> deleteMine({
    required String chatId,
    required String userId,
    required List<String> prekeyIds,
  }) async {
    deleted.add(List.of(prekeyIds));
    onServer.removeWhere(prekeyIds.contains);
  }

  @override
  Future<void> publish({
    required String chatId,
    required String userId,
    required List<PublishedPrekey> prekeys,
  }) async =>
      publishes++;

  @override
  Future<void> deleteMyConsumed({
    required String chatId,
    required String userId,
  }) async {}

  @override
  Future<PublishedPrekey?> claim({
    required String chatId,
    required String recipientId,
  }) async =>
      null;
}

class _FakeLocal implements PrekeyLocalRepository {
  _FakeLocal(this.ids);
  final Set<String> ids;

  @override
  Future<Set<String>> idsForChat(String chatId) async => Set.of(ids);

  @override
  Future<void> insert({
    required String prekeyId,
    required String chatId,
    required String privateBlob,
  }) async =>
      ids.add(prekeyId);

  @override
  Future<String?> privateBlobFor(String prekeyId) async => null;

  @override
  Future<int> delete(String prekeyId) async => ids.remove(prekeyId) ? 1 : 0;

  @override
  Future<void> deleteForChat(String chatId) async => ids.clear();
}

class _FakeSigner implements KemKeySigner {
  @override
  Future<String> sign(String chatId, String publicBlob) async => publicBlob;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _ids(String prefix, int n) =>
    [for (var i = 0; i < n; i++) '$prefix$i'];

void main() {
  group('orphanPrekeyIds', () {
    test('liefert nur Schlüssel ohne lokalen privaten Teil, in Server-Reihenfolge', () {
      expect(orphanPrekeyIds(['a', 'b', 'c', 'd'], {'b', 'd'}), ['a', 'c']);
    });

    test('nichts verwaist, wenn alles lokal vorhanden ist', () {
      expect(orphanPrekeyIds(['a', 'b'], {'a', 'b', 'x'}), isEmpty);
    });

    test('alles verwaist nach einer Wiederherstellung (lokal leer)', () {
      expect(orphanPrekeyIds(['a', 'b'], <String>{}), ['a', 'b']);
    });
  });

  group('PrekeyManager.replenishIfLow', () {
    test('löscht fremde Schlüssel und lässt eigene stehen', () async {
      final mine = _ids('mine', 20);
      final foreign = _ids('old', 5);
      final remote = _FakeRemote([...foreign, ...mine]);
      final local = _FakeLocal(mine.toSet());
      await PrekeyManager(local, remote, _FakeSigner())
          .replenishIfLow('chat', 'me');

      expect(remote.deleted, [foreign]);
      expect(remote.onServer, mine);
      // 20 eigene bleiben, das liegt über der Schwelle: kein neuer Vorrat nötig.
      expect(remote.publishes, 0);
    });

    test('nach einer Wiederherstellung wird der ganze alte Vorrat entfernt', () async {
      // Der Fall vom 2026-10-11: 94 Schlüssel des alten Geräts, lokal keiner.
      final remote = _FakeRemote(_ids('old', 94));
      final local = _FakeLocal(<String>{});
      await PrekeyManager(local, remote, _FakeSigner())
          .replenishIfLow('chat', 'me');

      expect(remote.deleted.single, hasLength(94));
      expect(remote.onServer.where((id) => id.startsWith('old')), isEmpty,
          reason: 'kein Schlüssel des alten Geräts darf mehr beanspruchbar sein');
    });

    test('ein voller eigener Vorrat bleibt unangetastet', () async {
      final mine = _ids('mine', 12);
      final remote = _FakeRemote(List.of(mine));
      await PrekeyManager(_FakeLocal(mine.toSet()), remote, _FakeSigner())
          .replenishIfLow('chat', 'me');

      expect(remote.deleted, isEmpty);
      expect(remote.publishes, 0);
    });
  });
}
