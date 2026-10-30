// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-12: a chat request sent while the receiving app sat in the
// background appeared only after a restart. The list refreshed solely on the
// live `chatRequest` event, which a backgrounded app never hears. These tests
// pin the catch-up on resume, and that an offline resume keeps the inbox.

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/lifecycle/app_lifecycle_service.dart';
import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/chat_requests/chat_request_model.dart';
import 'package:chattr/features/chat_requests/chat_requests_controller.dart';
import 'package:chattr/features/chat_requests/chat_requests_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuth extends StateNotifier<String?> implements AuthController {
  _FakeAuth() : super('me');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRepo implements ChatRequestsRepository {
  List<IncomingChatRequest> next = [];
  Object? failWith;
  int calls = 0;

  @override
  Future<List<IncomingChatRequest>> incoming() async {
    calls++;
    if (failWith != null) throw failWith!;
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

IncomingChatRequest _req(String id) => (
      requesterId: id,
      username: id,
      avatarPath: null,
      identityPublicKey: null,
      createdAt: DateTime.utc(2026, 10, 12),
    );

void main() {
  late _FakeRepo repo;
  late AppLifecycleService lifecycle;
  late ProviderContainer c;

  setUp(() {
    repo = _FakeRepo();
    lifecycle = AppLifecycleService();
    c = ProviderContainer(overrides: [
      authControllerProvider.overrideWith((ref) => _FakeAuth()),
      eventBusProvider.overrideWithValue(null),
      chatRequestsRepositoryProvider.overrideWithValue(repo),
      appLifecycleServiceProvider.overrideWithValue(lifecycle),
    ]);
    addTearDown(c.dispose);
    addTearDown(lifecycle.dispose);
  });

  Future<List<IncomingChatRequest>> list() =>
      c.read(incomingChatRequestsProvider.future);

  test('nach der Rückkehr in die App steht eine neue Anfrage da', () async {
    c.listen(incomingChatRequestsProvider, (_, _) {});
    expect(await list(), isEmpty);

    repo.next = [_req('linux-gerre')];
    lifecycle.notifyResumed();
    await Future<void>.delayed(Duration.zero);

    expect(await list(), hasLength(1));
    expect(c.read(incomingChatRequestCountProvider), 1);
  });

  test('offline zurück: die vorhandene Liste bleibt', () async {
    repo.next = [_req('a')];
    c.listen(incomingChatRequestsProvider, (_, _) {});
    expect(await list(), hasLength(1));

    repo.failWith = Exception('offline');
    lifecycle.notifyResumed();
    await Future<void>.delayed(Duration.zero);

    expect(repo.calls, 2, reason: 'es wurde nachgesehen');
    expect(c.read(incomingChatRequestCountProvider), 1,
        reason: 'ein Fehler leert das Postfach nicht');
  });
}
