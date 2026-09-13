// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The contact sheet. The one case this is about: whoever taps a member in a
// GROUP sees a sheet about that person — and no row in it may lead into the
// group. That is exactly what "contact info" did: `chat` is the group there, so
// the tap on David landed in the group info (reported 2026-08-23 from the
// device).
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key, so the
// assertions are on keys.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/identity/identity_verification_controller.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/profiles/widgets/profile_info_sheet.dart';

const _meId = 'aaaaaaaa-1111-4111-8111-111111111111';
const _davidId = 'eeeeeeee-5555-4555-8555-555555555555';
const _chatId = 'dddddddd-4444-4444-8444-444444444444';

class _FakeChats extends StateNotifier<List<Chat>> implements ChatsController {
  _FakeChats(super.state);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeProfiles extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfiles(super.state);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Chat _chat({required bool isGroup}) => Chat(
      id: _chatId,
      createdAt: DateTime.utc(2026, 5, 4),
      insertedAt: DateTime.utc(2026, 5, 4),
      name: isGroup ? 'Testgruppe' : null,
      isGroup: isGroup,
      admins: const [_meId],
    );

void main() {
  Future<void> openSheet(
    WidgetTester tester, {
    required Chat chat,
    String? otherUserId,
  }) async {
    // A taller surface: on the 800x600 of the default test surface the sheet
    // overflows by 0.5 px — an artefact of the test surface, not a fault of the
    // view (on the device there is plenty of room).
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          // GroupAvatar reads the chat out here — without the stand-in the real
          // controller reaches for Supabase, which does not exist in the test.
          chatsControllerProvider.overrideWith((ref) => _FakeChats([chat])),
          profilesControllerProvider.overrideWith(
            (ref) => _FakeProfiles({
              _davidId: Profile(
                id: _davidId,
                username: 'David',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            }),
          ),
          chatVerificationProvider.overrideWith(
            (ref, id) async => const ChatVerificationSummary({}),
          ),
          avatarSignedUrlProvider.overrideWith((ref, args) => null),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showProfileInfoSheet(
                  context: context,
                  chat: chat,
                  displayName: otherUserId == null ? 'Testgruppe' : 'David',
                  otherUserId: otherUserId,
                ),
                child: const Text('auf'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('auf'));
    await tester.pumpAndSettle();
  }

  testWidgets('a group member: no row leading into the group',
      (tester) async {
    await openSheet(tester, chat: _chat(isGroup: true), otherUserId: _davidId);

    expect(find.text('David'), findsOneWidget);
    // Verifying belongs to the person and stays.
    expect(find.text('profile.verify'), findsOneWidget);
    // Der Fund: fuehrte in die Gruppen-Info statt zu David.
    expect(find.text('profile.contact_info'), findsNothing);
  });

  testWidgets('group overview: contact info shows the group, and that is right',
      (tester) async {
    await openSheet(tester, chat: _chat(isGroup: true));

    expect(find.text('profile.members'), findsOneWidget);
    expect(find.text('profile.contact_info'), findsOneWidget);
  });

  testWidgets('1:1: contact info stays — the chat IS the contact',
      (tester) async {
    await openSheet(tester, chat: _chat(isGroup: false), otherUserId: _davidId);

    expect(find.text('profile.verify'), findsOneWidget);
    expect(find.text('profile.contact_info'), findsOneWidget);
  });
}
