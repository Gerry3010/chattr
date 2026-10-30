// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The number on the app icon has two consumers, and they have to see the same
// one: the operating system (foreground) and the iOS notification extension
// (background). The extension can only ADD — it reads the last published state
// as a base and counts delivered pushes on top.
//
// From that follows the property this test pins down: the state has to be
// published on EVERY change, including when it RISES. Whoever shortens that to
// "only on reset" leaves a stale base behind, and every further push moves the
// number a little further from the truth — silently, because a wrong number on
// the icon looks like a right one.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/lifecycle/app_lifecycle_service.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/chats_load_status.dart';
import 'package:chattr/features/chats/unread_badge.dart';
import 'package:chattr/features/push_notifications/push_cache_bridge_ios.dart';

class _FakeChatsController extends StateNotifier<List<Chat>>
    implements ChatsController {
  _FakeChatsController(super.state);

  void setChats(List<Chat> chats) => state = chats;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Chat _chat(String id, int unread) => Chat(
      id: id,
      createdAt: DateTime.utc(2026, 8, 1),
      insertedAt: DateTime.utc(2026, 8, 1),
      name: 'c$id',
      isGroup: true,
      unreadCount: unread,
    );

const _idA = 'aaaaaaaa-1111-4111-8111-111111111111';
const _idB = 'bbbbbbbb-2222-4222-8222-222222222222';

void main() {
  const channel = MethodChannel('net.geraldhofbauer.chattr/push_cache');
  late List<int> veroeffentlicht;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    veroeffentlicht = <int>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'unreadTotal') {
        final args = (call.arguments as Map).cast<String, Object?>();
        veroeffentlicht.add(args[pushUnreadTotalKey]! as int);
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ProviderContainer host(
    _FakeChatsController fake, {
    ChatsLoadStatus status = ChatsLoadStatus.ready,
  }) {
    final c = ProviderContainer(
      overrides: [
        chatsControllerProvider.overrideWith((ref) => fake),
        chatsLoadStatusProvider.overrideWith((ref) => status),
      ],
    );
    addTearDown(c.dispose);
    // Without a real listener the derived sum stays unobserved and is not
    // recomputed on a state change — the listener in the provider would then
    // never have anything to report. In the app `ChattrApp` takes care of that,
    // watching `appBadgeSyncProvider` permanently.
    c.listen<int>(totalUnreadProvider, (_, __) {});
    c.read(appBadgeSyncProvider);
    return c;
  }

  test('gesperrt oder noch nicht geladen: keine 0 aufs Symbol', () async {
    // 2026-10-23: Face ID abgebrochen, die Liste blieb leer, und genau diese
    // leere Liste schrieb eine 0 aufs Symbol und in die Basis der Erweiterung.
    final fake = _FakeChatsController(const []);
    final c = host(fake, status: ChatsLoadStatus.locked);
    await Future<void>.delayed(Duration.zero);
    c.read(appLifecycleServiceProvider).notifyResumed();
    await Future<void>.delayed(Duration.zero);
    expect(veroeffentlicht, isEmpty);

    fake.setChats([_chat(_idA, 2), _chat(_idB, 1)]);
    c.read(chatsLoadStatusProvider.notifier).state = ChatsLoadStatus.ready;
    await Future<void>.delayed(Duration.zero);
    expect(veroeffentlicht, [3],
        reason: 'sobald die Liste steht, gilt ihre Zahl');
  });

  test('the state is published when it RISES too', () async {
    final fake = _FakeChatsController([_chat(_idA, 0)]);
    host(fake);
    await Future<void>.delayed(Duration.zero);

    fake.setChats([_chat(_idA, 3)]);
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht, contains(3),
        reason: 'otherwise the extension base stays stale and every push drifts further'
            'weitere Push entfernt die Zahl weiter von der Wahrheit');
  });

  test('a reset to zero is published', () async {
    final fake = _FakeChatsController([_chat(_idA, 5)]);
    host(fake);
    await Future<void>.delayed(Duration.zero);

    fake.setChats([_chat(_idA, 0)]);
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht.last, 0,
        reason: 'without it the badge would stay after reading');
  });

  test('the state is the SUM across all chats', () async {
    final fake = _FakeChatsController([_chat(_idA, 2), _chat(_idB, 4)]);
    host(fake);
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht.first, 6,
        reason: 'the extension sets ONE badge for the whole app');
  });

  test('an unchanged number is not published again', () async {
    // The chat list is rebuilt on every event; without the equality check every
    // keystroke would write into the group container.
    final fake = _FakeChatsController([_chat(_idA, 2)]);
    host(fake);
    await Future<void>.delayed(Duration.zero);
    final afterStart = veroeffentlicht.length;

    fake.setChats([_chat(_idA, 2)]);
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht.length, afterStart);
  });

  test('the return to the foreground publishes AGAIN, unchanged number and all',
      () async {
    // The real point of this test. The extension raises the badge by itself and
    // can only ever ADD; a push that creates no unread message (a reaction, a
    // join request) therefore moves the icon without moving the local total.
    // A change-only listener has no occasion to take that back — the badge then
    // has no way down at all. So the resume has to re-assert the truth even
    // when, from the app's point of view, nothing happened.
    final fake = _FakeChatsController([_chat(_idA, 0)]);
    final c = host(fake);
    await Future<void>.delayed(Duration.zero);
    final nachStart = veroeffentlicht.length;

    c.read(appLifecycleServiceProvider).notifyResumed();
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht.length, nachStart + 1,
        reason: 'without it a base raised by the extension stays raised forever');
    expect(veroeffentlicht.last, 0);
  });

  test('the resume re-asserts the REAL total, not zero', () async {
    // Forcing a 0 here was tried once and flashed a wrong count whenever unread
    // chats remained. Whoever shortens the re-assert to "clear it" brings that
    // back.
    final fake = _FakeChatsController([_chat(_idA, 2), _chat(_idB, 3)]);
    final c = host(fake);
    await Future<void>.delayed(Duration.zero);

    c.read(appLifecycleServiceProvider).notifyResumed();
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht.last, 5);
  });

  test('on Android nothing is published', () async {
    // Android hat `aps.badge` nie benutzt und keine zweite Instanz, die
    // Benachrichtigungen aus unseren Daten baut.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final fake = _FakeChatsController([_chat(_idA, 7)]);
    host(fake);
    await Future<void>.delayed(Duration.zero);

    expect(veroeffentlicht, isEmpty);
  });
}
