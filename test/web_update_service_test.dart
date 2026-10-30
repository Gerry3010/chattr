// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chattr/core/updates/web_update_listener.dart';
import 'package:chattr/core/updates/web_update_service.dart';

void main() {
  ProviderContainer containerWith(http.Client client) {
    final container = ProviderContainer(overrides: [
      webUpdateServiceProvider.overrideWith(
        (ref) => WebUpdateService(ref, client: client),
      ),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  MockClient versionClient(String Function() version) {
    return MockClient((request) async {
      expect(request.url.path, endsWith('version.json'));
      // The cache-buster must not be named `v` — Flutter's service worker
      // strips `?v=` and would serve its cached version.json forever.
      expect(request.url.queryParameters.containsKey('v'), isFalse);
      return http.Response(
        '{"app_name":"chattr","version":"${version()}","build_number":"1"}',
        200,
      );
    });
  }

  test('first fetch is the baseline, same version raises nothing', () async {
    final container = containerWith(versionClient(() => '1.0.0'));
    final service = container.read(webUpdateServiceProvider);

    await service.checkNow(); // baseline
    await service.checkNow(); // unchanged
    expect(container.read(webUpdateAvailableProvider), isFalse);
  });

  test('a served version different from the baseline flips the provider',
      () async {
    var version = '1.0.0';
    final container = containerWith(versionClient(() => version));
    final service = container.read(webUpdateServiceProvider);

    await service.checkNow(); // baseline 1.0.0
    version = '1.0.1'; // deploy happens while the session is open
    await service.checkNow();
    expect(container.read(webUpdateAvailableProvider), isTrue);
  });

  test('failed fetches are ignored and do not poison the baseline', () async {
    var fail = true;
    var version = '1.0.0';
    final client = MockClient((request) async {
      if (fail) return http.Response('nginx error', 502);
      return http.Response('{"version":"$version","build_number":"1"}', 200);
    });
    final container = containerWith(client);
    final service = container.read(webUpdateServiceProvider);

    await service.checkNow(); // 502 — no baseline yet
    fail = false;
    await service.checkNow(); // first success = baseline
    expect(container.read(webUpdateAvailableProvider), isFalse);
    version = '2.0.0';
    await service.checkNow();
    expect(container.read(webUpdateAvailableProvider), isTrue);
  });

  testWidgets('WebUpdateListener raises a MaterialBanner when an update lands',
      (tester) async {
    // tr() falls back to the raw key without EasyLocalization — fine here,
    // we only assert the banner appears.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: WebUpdateListener(
            child: Scaffold(body: Text('content')),
          ),
        ),
      ),
    );
    expect(find.byType(MaterialBanner), findsNothing);

    container.read(webUpdateAvailableProvider.notifier).state = true;
    await tester.pumpAndSettle();

    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('app_update.reload'), findsOneWidget);
  });
}
