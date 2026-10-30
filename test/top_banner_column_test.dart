// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/core/network/device_connectivity.dart';
import 'package:chattr/screens/chat/components/server_offline_banner.dart';
import 'package:chattr/screens/chat/components/top_banner_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _statusBar = 40.0;
const _bannerBody = 20.0;

/// Pads for the status bar like the real banners do.
class _Banner extends StatelessWidget {
  const _Banner(this.visible, {super.key});
  final bool visible;

  @override
  Widget build(BuildContext context) => visible
      ? const SafeArea(bottom: false, child: SizedBox(height: _bannerBody))
      : const SizedBox.shrink();
}

/// Stands in for the chat's app bar: reports the inset it would pad by and
/// counts how often its state was created.
class _Content extends StatefulWidget {
  const _Content();
  static int created = 0;
  static double seenTop = -1;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  @override
  void initState() {
    super.initState();
    _Content.created++;
  }

  @override
  Widget build(BuildContext context) {
    _Content.seenTop = MediaQuery.paddingOf(context).top;
    return const SizedBox.expand();
  }
}

Widget _host(bool first, bool second) => MediaQuery(
      data: const MediaQueryData(
        size: Size(400, 800),
        padding: EdgeInsets.only(top: _statusBar),
        viewPadding: EdgeInsets.only(top: _statusBar),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: TopBannerColumn(
          banners: [
            (banner: _Banner(first, key: const Key('a')), visible: first),
            (banner: _Banner(second, key: const Key('b')), visible: second),
          ],
          child: const _Content(),
        ),
      ),
    );

double _height(WidgetTester tester, String key) =>
    tester.getSize(find.byKey(Key(key))).height;

void main() {
  setUp(() {
    _Content.created = 0;
    _Content.seenTop = -1;
  });

  group('Statusleisten-Abstand über der Kopfleiste', () {
    testWidgets('ohne Banner polstert die Kopfleiste selbst', (tester) async {
      await tester.pumpWidget(_host(false, false));
      expect(_Content.seenTop, _statusBar);
    });

    testWidgets('sichtbares Banner nimmt den Abstand, darunter keiner mehr',
        (tester) async {
      await tester.pumpWidget(_host(true, false));
      expect(_height(tester, 'a'), _statusBar + _bannerBody);
      expect(_Content.seenTop, 0, reason: 'sonst doppelte Lücke');
    });

    testWidgets('zwei Banner: nur das obere polstert', (tester) async {
      await tester.pumpWidget(_host(true, true));
      expect(_height(tester, 'a'), _statusBar + _bannerBody);
      expect(_height(tester, 'b'), _bannerBody);
      expect(_Content.seenTop, 0);
    });

    testWidgets('nur das untere sichtbar: es polstert, die Kopfleiste nicht',
        (tester) async {
      await tester.pumpWidget(_host(false, true));
      expect(_height(tester, 'b'), _statusBar + _bannerBody);
      expect(_Content.seenTop, 0);
    });

    testWidgets('Inhalt behält seinen Zustand, wenn das Banner kommt und geht',
        (tester) async {
      await tester.pumpWidget(_host(false, false));
      await tester.pumpWidget(_host(true, false));
      await tester.pumpWidget(_host(false, false));
      expect(_Content.created, 1);
      expect(_Content.seenTop, _statusBar);
    });
  });

  group('serverBannerProvider', () {
    ServerBannerKind? read(bool offline, ServerConnection server) {
      final c = ProviderContainer(overrides: [
        deviceOfflineProvider.overrideWithBuild((ref, _) => offline),
        serverConnectionProvider.overrideWithValue(AsyncData(server)),
      ]);
      addTearDown(c.dispose);
      return c.read(serverBannerProvider);
    }

    test('kein Netz geht vor Server weg', () {
      expect(read(true, ServerConnection.unreachable),
          ServerBannerKind.deviceOffline);
    });

    test('Netz da, Server weg', () {
      expect(read(false, ServerConnection.unreachable),
          ServerBannerKind.serverUnreachable);
    });

    test('kurzes Wiederverbinden zeigt nichts', () {
      expect(read(false, ServerConnection.reconnecting), isNull);
      expect(read(false, ServerConnection.connected), isNull);
    });
  });
}
