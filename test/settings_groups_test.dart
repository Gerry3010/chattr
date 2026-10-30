// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-58: the settings were one long list. Now a first level of groups, each
// opening its own screen; the new switches (CHAT-15, CHAT-38) live there.

import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedOut extends StateNotifier<String?> implements AuthController {
  _SignedOut() : super(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'chattr',
      packageName: 'net.geraldhofbauer.chattr',
      version: '1.32.3',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('Übersicht zeigt Gruppen, „Chats & Medien“ hat die Doppeltipp-Reaktion',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [authControllerProvider.overrideWith((ref) => _SignedOut())],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pump();

    for (final group in [
      'notifications',
      'chats',
      'calls',
      'privacy',
      'security',
      'data',
    ]) {
      expect(find.byKey(ValueKey('settings_group_$group')), findsOneWidget,
          reason: group);
    }

    await tester.tap(find.byKey(const ValueKey('settings_group_chats')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('double_tap_reaction_tile')),
        findsOneWidget);
    expect(find.text('❤️'), findsOneWidget);
  });
}
