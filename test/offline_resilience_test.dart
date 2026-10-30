// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-63: what the app keeps doing without network. The names are CHAT-62
// (roster_cache_test.dart); the text field is chat_view_textfield_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/features/messages/message_reaction_model.dart';
import 'package:chattr/features/messages/message_reactions_local_dao.dart';
import 'package:chattr/features/messages/message_reactions_repository.dart';

const _me = 'aaaaaaaa-0000-4000-8000-000000000001';
const _peer = 'bbbbbbbb-0000-4000-8000-000000000002';

ReactionSummary _summary(String reaction, List<String> users) =>
    ReactionSummary(
      reaction: reaction,
      count: users.length,
      userReacted: users.contains(_me),
      userIds: users,
    );

void main() {
  group('Nachholen beim ersten Abo', () {
    test('normaler Start: das erste Abo holt nichts nach', () {
      expect(
        EventBusService.catchUpOnSubscribe(
          everSubscribed: false,
          failedBeforeFirst: false,
        ),
        isFalse,
      );
    });

    test('Start ohne Netz: das erste Abo danach holt nach', () {
      expect(
        EventBusService.catchUpOnSubscribe(
          everSubscribed: false,
          failedBeforeFirst: true,
        ),
        isTrue,
      );
    });

    test('jedes spätere Abo holt nach', () {
      expect(
        EventBusService.catchUpOnSubscribe(
          everSubscribed: true,
          failedBeforeFirst: false,
        ),
        isTrue,
      );
    });
  });

  group('Reaktionen ohne Netz', () {
    late MessageReactionsLocalDao dao;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // Its own directory: `flutter test` runs files in parallel, and the
      // DatabaseService singleton would otherwise share one chattr.db with
      // every other DB test ("database is locked").
      await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('chattr_db_').path,
      );
    });

    setUp(() async {
      await DatabaseService.instance.close();
      await DatabaseService.instance.deleteDatabase();
      dao = MessageReactionsLocalDao(DatabaseService.instance);
    });

    test('was der Server beim Öffnen liefert, steht offline wieder da',
        () async {
      await dao.replaceForMessages(
        ['m1', 'm2'],
        {
          'm1': [
            _summary('👍', [_peer, _me]),
            _summary('😂', [_peer]),
          ],
        },
      );

      final local = await dao.getReactionSummaries(['m1', 'm2'], _me);
      expect(local.keys, ['m1'], reason: 'm2 hat keine Reaktionen');
      final thumbs = local['m1']!.firstWhere((s) => s.reaction == '👍');
      expect(thumbs.count, 2);
      expect(thumbs.userReacted, isTrue);
      expect(thumbs.userIds.toSet(), {_peer, _me});
    });

    test('die Serverantwort ersetzt, statt zu sammeln', () async {
      await dao.replaceForMessages(['m1'], {
        'm1': [_summary('👍', [_peer, _me])],
      });
      // I took mine back, the peer switched to ❤️.
      await dao.replaceForMessages(['m1'], {
        'm1': [_summary('❤️', [_peer])],
      });
      final local = await dao.getReactionSummaries(['m1'], _me);
      expect(local['m1']!.map((s) => s.reaction), ['❤️']);
      expect(local['m1']!.single.userReacted, isFalse);

      // And no reactions at all now: the message is cleared.
      await dao.replaceForMessages(['m1'], const {});
      expect(await dao.getReactionSummaries(['m1'], _me), isEmpty);
    });

    test('ein alter Server ohne Namensliste löscht nichts', () async {
      await dao.replaceForMessages(['m1'], {
        'm1': [_summary('👍', [_peer])],
      });
      await dao.replaceForMessages(['m1'], {
        'm1': [
          const ReactionSummary(reaction: '👍', count: 3, userReacted: false),
        ],
      });
      final local = await dao.getReactionSummaries(['m1'], _me);
      expect(local['m1']!.single.count, 1,
          reason: 'aus count allein lassen sich keine Zeilen bauen');
    });

    test('ohne Server antwortet das Repository aus der lokalen Tabelle',
        () async {
      await dao.replaceForMessages(['m1'], {
        'm1': [_summary('👍', [_peer])],
      });
      // Nothing listens on port 9: the RPC fails like it does offline.
      final repo = MessageReactionsRepository(
        SupabaseClient('http://127.0.0.1:9', 'anon'),
        dao,
      );
      final summaries =
          await repo.getReactionSummaries(['m1'], currentUserId: _me);
      expect(summaries['m1']!.single.reaction, '👍');
    });
  });
}
