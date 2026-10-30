// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Where the "important" switch may appear (1.26.2).
//
// The urgency arises in the iOS notification extension. On Android the channel
// is already on high importance anyway, in the browser the level does not exist
// at all — there the switch would be a promise nobody keeps. A switch that does
// nothing is worse than none: it lets the user believe they have set something.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/profiles/important_people_controller.dart';
import 'package:chattr/features/profiles/profile_model.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/profiles/widgets/important_person_tile.dart';

const _anna = 'aaaaaaaa-1111-4111-8111-111111111111';
const _bot = 'cccccccc-3333-4333-8333-333333333333';

class _FakeProfiles extends StateNotifier<Map<String, Profile>>
    implements ProfilesController {
  _FakeProfiles(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Profile _profile(String id, String name, {bool isAgent = false}) => Profile(
      id: id,
      username: name,
      createdAt: DateTime.utc(2026, 1, 1),
      isAgent: isAgent,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    ImportantPersonTile.supported = () => true;
    addTearDown(() => ImportantPersonTile.supported = () => true);
  });

  Future<void> pump(WidgetTester tester, String userId,
      {Set<String> wichtig = const {}}) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          profilesControllerProvider.overrideWith(
            (ref) => _FakeProfiles({
              _anna: _profile(_anna, 'Anna'),
              _bot: _profile(_bot, 'chattr-agent', isAgent: true),
            }),
          ),
          importantPeopleProvider.overrideWith(
            (ref) => _StubImportant(wichtig),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: ImportantPersonTile(userId: userId)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('on iOS the switch is there', (tester) async {
    await pump(tester, _anna);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });

  testWidgets('it shows the stored state', (tester) async {
    await pump(tester, _anna, wichtig: {_anna});
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isTrue);
  });

  testWidgets('elsewhere it does not exist', (tester) async {
    // Android/web: the channel is already up, or the level does not exist.
    ImportantPersonTile.supported = () => false;
    await pump(tester, _anna);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('an agent can be marked too', (tester) async {
    // This originally stood the other way round, on the grounds that an agent
    // only writes on request. That is not true: it reports of its own accord
    // too — status, the result of a job — and a message like that can be
    // exactly the one meant to get through the focus (Gerry, 2026-08-27). The
    // test remains regardless, with the sign reversed: the kind of account must
    // not decide whom the user may call important.
    await pump(tester, _bot);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}

class _StubImportant extends ImportantPeopleController {
  _StubImportant(Set<String> initial)
      : super(const FlutterSecureStorage(), mirror: _keinSpiegel) {
    state = initial;
  }

  static Future<void> _keinSpiegel(Set<String> ids) async {}
}
