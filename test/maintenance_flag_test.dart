// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The maintenance switch (Gerry, 2026-08-31). The most important guarantee here
// is the uncomfortable one: **unreachable does NOT mean "maintenance".** Were
// it the other way round, a typo in the address or an expired certificate would
// switch deletion off forever and unnoticed — a genuine remote deletion would
// then have no effect, without anybody noticing.
//
// The automatic brake is the grace period (`account_gone_guard.dart`), and that
// needs no network. The switch is the deliberate override on top.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chattr/core/init/maintenance_flag.dart';

void main() {
  final target = Uri.parse('https://example.invalid/download/maintenance.json');

  MockClient antwortet(int code, String body) =>
      MockClient((_) async => http.Response(body, code));

  group('parse — only an explicit yes counts', () {
    test('the expected yes', () {
      expect(MaintenanceFlag.parse('{"maintenance": true}'), isTrue);
    });

    test('a no is a no', () {
      expect(MaintenanceFlag.parse('{"maintenance": false}'), isFalse);
    });

    test('anything unclear is a no', () {
      for (final body in [
        '',
        '{}',
        'null',
        '[]',
        '<html><h1>404</h1></html>', // Fehlerseite statt JSON
        '{"maintenance": "true"}', // Zeichenkette, nicht Wahrheitswert
        '{"maintenance": 1}',
        '{"wartung": true}',
      ]) {
        expect(MaintenanceFlag.parse(body), isFalse, reason: body);
      }
    });
  });

  group('isActive', () {
    test('200 with a yes switches maintenance on', () async {
      expect(
        await MaintenanceFlag.isActive(
            client: antwortet(200, '{"maintenance": true}'), override: target),
        isTrue,
      );
    });

    test('a 404 is not maintenance', () async {
      expect(
        await MaintenanceFlag.isActive(
            client: antwortet(404, '{"maintenance": true}'), override: target),
        isFalse,
        reason: 'the body counts only on a 200 — otherwise one reads an error page',
      );
    });

    test('a network error is NOT maintenance', () async {
      final kaputt = MockClient((_) async => throw http.ClientException('weg'));
      expect(
        await MaintenanceFlag.isActive(client: kaputt, override: target),
        isFalse,
        reason: 'otherwise a typo switches the deletion off forever',
      );
    });

    test('a timeout is NOT maintenance', () async {
      final haengt = MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return http.Response('{"maintenance": true}', 200);
      });
      expect(
        await MaintenanceFlag.isActive(
          client: haengt,
          override: target,
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });
  });

  group('timestamp — otherwise a cache answers', () {
    // Measured on 2026-09-01: Caddy dutifully serves `no-cache`, Cloudflare
    // replaces it with `max-age=14400`. For four hours the fleet would get the
    // answer from before — and because a 404 ("no file") looks exactly like "no
    // maintenance", the switch, once set, would be without effect and nobody
    // would notice.

    test('appends a timestamp', () {
      final mit = MaintenanceFlag.mitZeitstempel(target);
      expect(mit.queryParameters['t'], isNotNull);
      expect(int.tryParse(mit.queryParameters['t']!), isNotNull);
      expect(mit.path, target.path);
    });

    test('keeps existing parameters', () {
      final mit = MaintenanceFlag.mitZeitstempel(
          Uri.parse('https://example.invalid/m.json?kanal=beta'));
      expect(mit.queryParameters['kanal'], 'beta');
      expect(mit.queryParameters['t'], isNotNull);
    });

    test('the query really goes out with a timestamp', () async {
      Uri? gefragt;
      final c = MockClient((req) async {
        gefragt = req.url;
        return http.Response('{"maintenance": true}', 200);
      });
      expect(
          await MaintenanceFlag.isActive(client: c, override: target), isTrue);
      expect(gefragt!.queryParameters['t'], isNotNull);
      expect(gefragt!.removeFragment().replace(queryParameters: {}).path,
          target.path);
    });
  });
}
