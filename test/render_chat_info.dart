// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// NOT a test — a renderer. Deliberately not named `*_test.dart` so it does not
// run with the suite. Purpose: to really LOOK at the new chat info, with real
// German text and a real font, without starting the app.
//
// flutter test --update-goldens test/render_chat_info.dart --plain-name
// '<name>'
//
// ALWAYS invoke it individually (`--plain-name`): if several cases run one
// after another, the second EasyLocalization tree no longer builds in time and
// the image stays empty — a measurement artefact, not a fault in the screen.
//
// puts the images under test/goldens/.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/chats/chat_members_controller.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/mute_controller.dart';
import 'package:chattr/features/identity/identity_verification_controller.dart';
import 'package:chattr/features/identity/identity_verification_repository.dart';
import 'package:chattr/features/invites/invites_controller.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/screens/chat/info/chat_info_screen.dart';
import 'package:chattr/screens/chat/info/group_edit_screen.dart';

const meId = 'aaaaaaaa-1111-4111-8111-111111111111';
const chatId = 'dddddddd-4444-4444-8444-444444444444';
const namen = {
  'bbbbbbbb-2222-4222-8222-222222222222': 'SeB',
  'cccccccc-3333-4333-8333-333333333333': 'Mac-Claude',
  'eeeeeeee-5555-4555-8555-555555555555': 'jonnny',
  'ffffffff-6666-4666-8666-666666666666': 'galaxyfixtest',
};
const agentId = '99999999-7777-4777-8777-777777777777';

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
  bool isMuted(String id) => state.containsKey(id);
  @override
  DateTime? mutedUntil(String id) => state[id];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeProfiles extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfiles(super.state);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Profile _p(String id, String name, {bool agent = false}) => Profile(
      id: id,
      username: name,
      createdAt: DateTime.utc(2026, 1, 1),
      isAgent: agent,
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Load a real font — otherwise the test renderer draws nothing but boxes.
    Future<void> load(String familie, String path) async {
      final loader = FontLoader(familie);
      loader.addFont(
        File(path).readAsBytes().then(
              (b) => ByteData.view(Uint8List.fromList(b).buffer),
            ),
      );
      await loader.load();
    }

    await load('Roboto', '/usr/share/fonts/TTF/DejaVuSans.ttf');
    // Without the icon font the test renderer draws a little box instead of
    // every icon — and then precisely what one looks at the image for cannot be
    // judged.
    await load(
      'MaterialIcons',
      '${Platform.environment['HOME']}/flutter/bin/cache/artifacts/'
          'material_fonts/MaterialIcons-Regular.otf',
    );
    // EasyLocalization remembers the language in shared_preferences — in the
    // test there is no platform implementation for that.
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  final mitglieder = [meId, ...namen.keys, agentId];

  final gruppe = Chat(
    id: chatId,
    createdAt: DateTime.utc(2026, 5, 4),
    insertedAt: DateTime.utc(2026, 5, 4),
    name: 'Chattr-Agenten',
    description:
        'Koordination zwischen Linux- und Mac-Claude: PRs, Builds, Releases. '
        'Wer hier reinkommt, sollte den Branch-Flow kennen.',
    isGroup: true,
    admins: const [meId],
    messageTtlSeconds: null,
  );

  Widget host(Widget child, {Map<String, DateTime?> muted = const {}}) {
    return EasyLocalization(
      supportedLocales: const [Locale('de', 'DE')],
      path: 'assets/translations',
      fallbackLocale: const Locale('de', 'DE'),
      startLocale: const Locale('de', 'DE'),
      useOnlyLangCode: false,
      child: ProviderScope(
        overrides: [
          chatsControllerProvider.overrideWith((ref) => _FakeChats([gruppe])),
          authControllerProvider.overrideWith((ref) => _FakeAuth()),
          mutedChatsProvider.overrideWith((ref) => _FakeMute(muted)),
          profilesControllerProvider.overrideWith(
            (ref) => _FakeProfiles({
              meId: _p(meId, 'Gerry'),
              for (final e in namen.entries) e.key: _p(e.key, e.value),
              agentId: _p(agentId, 'chattr-agent', agent: true),
            }),
          ),
          chatMembersProvider.overrideWith((ref, id) async => mitglieder),
          pendingMembersProvider.overrideWith((ref, id) async => const []),
          chatInvitesProvider.overrideWith((ref, id) async => const []),
          chatVerificationProvider.overrideWith(
            (ref, id) async => ChatVerificationSummary({
              'bbbbbbbb-2222-4222-8222-222222222222':
                  IdentityVerificationState.verified,
              'cccccccc-3333-4333-8333-333333333333':
                  IdentityVerificationState.verified,
              'eeeeeeee-5555-4555-8555-555555555555':
                  IdentityVerificationState.unverified,
              'ffffffff-6666-4666-8666-666666666666':
                  IdentityVerificationState.changed,
            }),
          ),
          avatarSignedUrlProvider.overrideWith((ref, args) => null),
        ],
        child: Builder(
          builder: (context) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: ThemeData.dark(useMaterial3: true),
            home: child,
          ),
        ),
      ),
    );
  }

  Future<void> render(
    WidgetTester tester,
    Widget child,
    String name, {
    Map<String, DateTime?> muted = const {},
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 1900));
    await tester.pumpWidget(host(child, muted: muted));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('Chat-Info als Admin', (tester) async {
    await render(tester, ChatInfoScreen(chat: gruppe), 'chat_info_admin',
        muted: {chatId: DateTime(2026, 8, 22, 18)});
  });

  testWidgets('chat info in a 1:1', (tester) async {
    final direkt = Chat(
      id: chatId,
      createdAt: DateTime.utc(2026, 6, 12),
      insertedAt: DateTime.utc(2026, 6, 12),
      isGroup: false,
      admins: const [meId],
    );
    await tester.binding.setSurfaceSize(const Size(430, 1400));
    await tester.pumpWidget(host(ChatInfoScreen(chat: direkt)));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/chat_info_direct.png'),
    );
  });

  testWidgets('Gruppe bearbeiten', (tester) async {
    await render(tester, GroupEditScreen(chat: gruppe), 'group_edit');
  });
}
