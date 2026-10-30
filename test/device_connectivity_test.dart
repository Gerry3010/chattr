// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-63: "no network" and "server down" are different things, and the
// realtime channel reconnects the moment the network is back.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/core/network/device_connectivity.dart';
import 'package:chattr/screens/chat/components/server_offline_banner.dart';

const _none = [ConnectivityResult.none];
const _wifi = [ConnectivityResult.wifi];
const _mobile = [ConnectivityResult.mobile];

void main() {
  group('Regeln', () {
    test('offline ist nur „gar nichts“', () {
      expect(isOffline(_none), isTrue);
      expect(isOffline(const []), isTrue);
      expect(isOffline(_wifi), isFalse);
      expect(isOffline(const [ConnectivityResult.vpn]), isFalse);
      expect(isOffline(const [ConnectivityResult.none, ConnectivityResult.wifi]),
          isFalse);
    });

    test('Netz zurück: sofort neu verbinden', () {
      expect(
        reconnectOnNetworkChange(
            previous: _none, next: _wifi, channelConnected: false),
        isTrue,
      );
    });

    test('Wechsel unter einem toten Kanal: neu verbinden', () {
      expect(
        reconnectOnNetworkChange(
            previous: _wifi, next: _mobile, channelConnected: false),
        isTrue,
      );
    });

    test('Wechsel bei stehendem Kanal: nichts anfassen', () {
      expect(
        reconnectOnNetworkChange(
            previous: _wifi, next: _mobile, channelConnected: true),
        isFalse,
      );
    });

    test('ohne Netz nie neu verbinden', () {
      expect(
        reconnectOnNetworkChange(
            previous: _wifi, next: _none, channelConnected: false),
        isFalse,
      );
    });
  });

  group('Schonfrist', () {
    test('ein kurzes „kein Netz“ beim Wechsel zeigt nichts an', () {
      fakeAsync((async) {
        final results = StreamController<List<ConnectivityResult>>();
        final c = ProviderContainer(overrides: [
          connectivityResultsProvider.overrideWith((ref) => results.stream),
        ]);
        final sub = c.listen(deviceOfflineProvider, (_, _) {});

        results.add(_wifi);
        async.flushMicrotasks();
        results.add(_none);
        async.elapse(const Duration(milliseconds: 800));
        results.add(_mobile);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(deviceOfflineProvider), isFalse);

        results.add(_none);
        async.elapse(offlineGrace + const Duration(milliseconds: 100));
        expect(c.read(deviceOfflineProvider), isTrue);

        results.add(_wifi);
        async.flushMicrotasks();
        expect(c.read(deviceOfflineProvider), isFalse,
            reason: 'zurück gilt sofort');

        sub.close();
        c.dispose();
        results.close();
      });
    });
  });

  group('Hinweis', () {
    Widget host({required bool offline, required ServerConnection server}) {
      return ProviderScope(
        overrides: [
          deviceOfflineProvider.overrideWithBuild((ref, _) => offline),
          serverConnectionProvider
              .overrideWith((ref) => Stream.value(server)),
        ],
        child: const MaterialApp(home: Scaffold(body: ServerOfflineBanner())),
      );
    }

    testWidgets('Gerät offline: sagt „kein Netz“, nicht „Server“',
        (tester) async {
      await tester.pumpWidget(
          host(offline: true, server: ServerConnection.unreachable));
      await tester.pump();
      expect(find.text('server_status.device_offline_title'), findsOneWidget);
      expect(find.text('server_status.offline_title'), findsNothing);
    });

    testWidgets('Netz da, Server weg: sagt „Server“', (tester) async {
      await tester.pumpWidget(
          host(offline: false, server: ServerConnection.unreachable));
      await tester.pump();
      expect(find.text('server_status.offline_title'), findsOneWidget);
    });

    testWidgets('alles gut: kein Hinweis', (tester) async {
      await tester.pumpWidget(
          host(offline: false, server: ServerConnection.connected));
      await tester.pump();
      expect(find.byType(Material), findsWidgets);
      expect(find.textContaining('server_status'), findsNothing);
    });
  });
}
