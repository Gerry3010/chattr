// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The shared member row. There used to be two versions with different
// capabilities — above all the info view lacked the trust shield entirely.
// These tests pin down WHAT the one row shows and when it lets one manage.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key, so the
// assertions are on keys, not on German words.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/agents/main_agent_store.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/identity/identity_verification_repository.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/chat_requests/chat_request_model.dart';
import 'package:chattr/features/chat_requests/chat_requests_controller.dart';
import 'package:chattr/screens/chat/info/widgets/member_tile.dart';

const meId = 'aaaaaaaa-1111-4111-8111-111111111111';
const peerId = 'bbbbbbbb-2222-4222-8222-222222222222';
const botId = 'cccccccc-3333-4333-8333-333333333333';
const chatId = 'dddddddd-4444-4444-8444-444444444444';

class _FakeProfiles extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfiles(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMainAgent extends StateNotifier<String?>
    implements MainAgentController {
  _FakeMainAgent(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Profile _profile(String id, String name, {bool isAgent = false}) => Profile(
      id: id,
      username: name,
      createdAt: DateTime.utc(2026, 1, 1),
      isAgent: isAgent,
    );

Chat _chat({required bool isGroup, List<String> admins = const []}) => Chat(
      id: chatId,
      createdAt: DateTime.utc(2026, 7, 1),
      insertedAt: DateTime.utc(2026, 7, 1),
      name: 'Testgruppe',
      isGroup: isGroup,
      admins: admins,
    );

void main() {
  setUp(() {
    // The default test surface (800x600) is narrower than any device this row
    // runs on — name, two pills, shield and menu do not fit side by side there.
    // This measures the surface, not the tile.
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 1600);
    view.devicePixelRatio = 1.0;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  Future<void> pump(
    WidgetTester tester, {
    required Chat chat,
    required String memberId,
    required bool isCurrentUserAdmin,
    IdentityVerificationState? trust,
    bool showId = false,
    bool isAgentSection = false,
    String? mainAgent,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        // A key of its own per call: without it Riverpod keeps the container,
        // along with the StateNotifier it already created, on the second
        // `pumpWidget` in the same test — the new override then does not take,
        // and the test quietly measures the old state.
        key: UniqueKey(),
        overrides: [
          profilesControllerProvider.overrideWith(
            (ref) => _FakeProfiles({
              meId: _profile(meId, 'Gerry'),
              peerId: _profile(peerId, 'SeB'),
              botId: _profile(botId, 'chattr-agent', isAgent: true),
            }),
          ),
          mainAgentProvider.overrideWith((ref, id) => _FakeMainAgent(mainAgent)),
          // Avatars live in a private bucket; in the test there is no signed
          // address, so the initials circle renders.
          avatarSignedUrlProvider.overrideWith((ref, args) => null),
          // The profile sheet would otherwise ask the server whether we already
          // share a 1:1 — in the test there is none.
          chatRequestStatusProvider.overrideWith(
            (ref, id) async => (state: ChatRequestState.none, chatId: null),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MemberTile(
              chat: chat,
              memberId: memberId,
              currentUserId: meId,
              isCurrentUserAdmin: isCurrentUserAdmin,
              trust: trust,
              showId: showId,
              isAgentSection: isAgentSection,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the own row carries "you" and no trust shield',
      (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: meId,
      isCurrentUserAdmin: true,
      trust: IdentityVerificationState.verified,
    );

    expect(find.text('chat_members.you_badge'), findsOneWidget);
    // One does not verify oneself — a shield on one's own row would be a
    // statement about nobody.
    expect(find.byIcon(Icons.verified_user), findsNothing);
  });

  testWidgets('the admin pill stands only on an admin', (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );
    expect(find.text('chat_members.admin_badge'), findsNothing);

    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId, peerId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );
    expect(find.text('chat_members.admin_badge'), findsOneWidget);
  });

  testWidgets('the trust state is shown as a shield', (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
      trust: IdentityVerificationState.changed,
    );
    expect(find.byIcon(Icons.gpp_bad), findsOneWidget);
  });

  testWidgets('without a loaded state no shield stands there at all',
      (tester) async {
    // Better no shield than a wrong one: `null` means "not loaded yet", not
    // "not verified".
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
    );
    expect(find.byIcon(Icons.shield_outlined), findsNothing);
    expect(find.byIcon(Icons.verified_user), findsNothing);
    expect(find.byIcon(Icons.gpp_bad), findsNothing);
  });

  testWidgets('managing exists only as an admin in a group',
      (tester) async {
    // A non-admin in the group.
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [peerId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
    );
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    // Admin in der Gruppe
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);

    // Admin, but 1:1 — there neither manages the other, and the database
    // forbids it anyway (migration 00030).
    await pump(
      tester,
      chat: _chat(isGroup: false, admins: const [meId, peerId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('the main-agent star stands only in the agent section',
      (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: botId,
      isCurrentUserAdmin: true,
    );
    expect(find.byIcon(Icons.star_border), findsNothing);

    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: botId,
      isCurrentUserAdmin: true,
      isAgentSection: true,
    );
    expect(find.byIcon(Icons.star_border), findsOneWidget);

    // Gewaehlter Hauptagent → voller Stern + Beschriftung.
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: botId,
      isCurrentUserAdmin: true,
      isAgentSection: true,
      mainAgent: botId,
    );
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.text('chat_detail.main_agent'), findsOneWidget);
  });

  testWidgets('the id stands only in the full list', (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
    );
    expect(find.textContaining('ID: '), findsNothing);

    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
      showId: true,
    );
    expect(find.textContaining('ID: '), findsOneWidget);
  });

  // Gerry, 2026-08-25: "tap the whole cell … and the sheet would open — not
  // only the avatar. for admins too the promote actions should only open on the
  // three-dot trailing button and the sheet should always come."
  //
  // Before, a tap on the row led admins into the manage menu and everyone else
  // NOWHERE — the same row, two outcomes, and the route to the person was an
  // avatar one had to know about.

  testWidgets('the whole row opens the profile — without admin rights too',
      (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [peerId]),
      memberId: peerId,
      isCurrentUserAdmin: false,
    );

    await tester.tap(find.text('SeB'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('as an admin the row opens the profile, NOT the managing',
      (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );

    await tester.tap(find.text('SeB'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('chat_members.promote'), findsNothing,
        reason: 'managing belongs behind the three dots, not on the row');
  });

  testWidgets('the three dots open the managing, not the profile',
      (tester) async {
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: peerId,
      isCurrentUserAdmin: true,
    );

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('chat_members.promote'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the sheet offers an agent no chat request',
      (tester) async {
    // The MCP server knows only group joins; a chat request to it would lie
    // there forever, and the user would permanently see "request sent". So
    // nothing is offered in the first place.
    await pump(
      tester,
      chat: _chat(isGroup: true, admins: const [meId]),
      memberId: botId,
      isCurrentUserAdmin: true,
      isAgentSection: true,
    );

    await tester.tap(find.text('chattr-agent'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'the sheet itself still exists — only without the row');
    expect(find.text('chat_requests.send'), findsNothing);
    expect(find.text('chat_requests.open_chat'), findsNothing);
  });
}
