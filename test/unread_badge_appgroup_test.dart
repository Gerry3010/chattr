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

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
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

  ProviderContainer host(_FakeChatsController fake) {
    final c = ProviderContainer(
      overrides: [chatsControllerProvider.overrideWith((ref) => fake)],
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
