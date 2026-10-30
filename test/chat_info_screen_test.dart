// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The new chat info. What is checked is WHAT a section shows and to whom — the
// matrix of group/1:1 times admin/member. That is exactly where the old view
// became unmanageable: nine cards, each with an `if` condition of its own.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key, so the
// assertions are on keys.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/chats/chat_members_controller.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/mute_controller.dart';
import 'package:chattr/features/identity/identity_verification_controller.dart';
import 'package:chattr/features/invites/invites_controller.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/screens/chat/info/chat_info_screen.dart';

const meId = 'aaaaaaaa-1111-4111-8111-111111111111';
const peerId = 'bbbbbbbb-2222-4222-8222-222222222222';
const chatId = 'dddddddd-4444-4444-8444-444444444444';

class _FakeChats extends StateNotifier<List<Chat>> implements ChatsController {
  _FakeChats(super.state);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeAuth extends StateNotifier<String?> implements AuthController {
  _FakeAuth() : super(meId);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeMute extends StateNotifier<Map<String, DateTime?>>
    implements MuteController {
  _FakeMute(super.state);
  @override
  bool isMuted(String chatId) => state.containsKey(chatId);
  @override
  DateTime? mutedUntil(String chatId) => state[chatId];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeProfiles extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfiles(super.state);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Chat _chat({required bool isGroup, required List<String> admins}) => Chat(
      id: chatId,
      createdAt: DateTime.utc(2026, 5, 4),
      insertedAt: DateTime.utc(2026, 5, 4),
      name: isGroup ? 'Testgruppe' : null,
      description: isGroup ? 'Worum es hier geht.' : null,
      isGroup: isGroup,
      admins: admins,
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Chat chat,
    List<String> members = const [meId, peerId],
    Map<String, DateTime?> muted = const {},
  }) async {
    // A tall surface: the info is a `ListView`, and what lies below the visible
    // area is not built at all — "delete chat" would otherwise not be findable
    // although it is there.
    await tester.binding.setSurfaceSize(const Size(600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          chatsControllerProvider.overrideWith((ref) => _FakeChats([chat])),
          authControllerProvider.overrideWith((ref) => _FakeAuth()),
          mutedChatsProvider.overrideWith((ref) => _FakeMute(muted)),
          profilesControllerProvider.overrideWith(
            (ref) => _FakeProfiles({
              meId: Profile(
                id: meId,
                username: 'Gerry',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
              peerId: Profile(
                id: peerId,
                username: 'SeB',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            }),
          ),
          chatMembersProvider.overrideWith((ref, id) async => members),
          pendingMembersProvider.overrideWith((ref, id) async => const []),
          chatInvitesProvider.overrideWith((ref, id) async => const []),
          chatVerificationProvider.overrideWith(
            (ref, id) async => const ChatVerificationSummary({}),
          ),
          avatarSignedUrlProvider.overrideWith((ref, args) => null),
        ],
        child: MaterialApp(home: ChatInfoScreen(chat: chat)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    // Tall enough for the ListView to build ALL sections. Otherwise an ordering
    // test measures the size of the test surface instead of the order: what
    // lies below the edge does not exist in the widget tree at all.
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 3000);
    view.devicePixelRatio = 1.0;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  testWidgets('a group as an admin: pencil, invite, delete', (tester) async {
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('chat_detail.invite_short'), findsOneWidget);
    expect(find.text('chat_detail.delete_chat'), findsOneWidget);
    expect(find.text('chat_detail.leave_chat'), findsOneWidget);
  });

  testWidgets('a group as an ordinary member: no pencil, no delete',
      (tester) async {
    await pump(tester, chat: _chat(isGroup: true, admins: const [peerId]));

    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.text('chat_detail.invite_short'), findsNothing);
    expect(find.text('chat_detail.delete_chat'), findsNothing);
    // Die Selbstzerstoerungs-Zeile sagt, warum sie nicht reagiert, statt
    // stumm dazustehen.
    expect(find.text('chat_detail.ttl_admin_only'), findsOneWidget);
  });

  testWidgets('1:1: no member section, but blocking instead',
      (tester) async {
    await pump(tester, chat: _chat(isGroup: false, admins: const [meId]));

    expect(find.text('chat_detail.members'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.text('chat_detail.block_user'), findsOneWidget);
  });

  testWidgets('in a group there is no blocking', (tester) async {
    // Blocking applies to ONE person — in a group there is no unambiguous
    // counterpart.
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));
    expect(find.text('chat_detail.block_user'), findsNothing);
  });

  testWidgets('the notification row carries its state',
      (tester) async {
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));
    expect(find.text('chat_detail.notifications_on'), findsOneWidget);

    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      muted: {chatId: null},
    );
    expect(find.text('chat_detail.muted_forever'), findsOneWidget);
  });

  testWidgets('no edit field in the info any more', (tester) async {
    // The actual point of the rebuild: the info shows, it does not edit.
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the management section stays away when there is nothing to do',
      (tester) async {
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));
    expect(find.text('chat_detail.section_admin'), findsNothing);
  });

  testWidgets('the members stand BELOW the settings', (tester) async {
    // Gerry, 2026-08-25: the member section grows — five people are capped, the
    // agents below them are not. If it stood at the top, it pushed everything
    // settable off the bottom of the screen in a project chat, and one had to
    // pass the whole list to mute.
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));

    double y(String key) =>
        tester.getTopLeft(find.text(key)).dy;

    expect(y('chat_detail.section_settings'),
        lessThan(y('chat_detail.members')),
        reason: 'Einstellungen zuerst, danach erst die lange Liste');
  });

  testWidgets('leaving and deleting stay the end', (tester) async {
    // What cannot be undone belongs below everything else — below the members
    // too, which have just moved down.
    await pump(tester, chat: _chat(isGroup: true, admins: const [meId]));

    expect(
      tester.getTopLeft(find.text('chat_detail.members')).dy,
      lessThan(tester.getTopLeft(find.text('chat_detail.delete_chat')).dy),
    );
  });
}
