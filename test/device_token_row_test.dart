// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// What a device claims about itself when it renews its push token.
//
// Every field of this row is a statement the server then acts on:
// `local_render` decides whether a notification arrives readable at all, and
// `app_version` (00076) decides when a migration like 00075 is let loose. If an
// invented or empty version stands there, the server takes an old device for a
// new one — and takes its profile pictures away at the next rollout step.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/features/push_notifications/device_token_repository.dart';

void main() {
  Map<String, dynamic> row({
    String platform = 'android',
    String? appVersion,
  }) =>
      DeviceTokenRepository.tokenRow(
        userId: 'u1',
        token: 't1',
        platform: platform,
        appVersion: appVersion,
        now: DateTime.utc(2026, 8, 13, 22, 30),
      );

  test('the version travels along as a plain number', () {
    expect(row(appVersion: '1.23.1')['app_version'], '1.23.1');
  });

  test('without a version the field is missing — not null, not empty', () {
    // A NULL sent along would overwrite an already known version on an existing
    // row; a missing field leaves it standing.
    expect(row().containsKey('app_version'), isFalse);
  });

  test('an empty version counts as none', () {
    expect(row(appVersion: '   ').containsKey('app_version'), isFalse);
  });

  test('whitespace is trimmed, so that 1.23.1 with a trailing space is not a line of its own'
      'Version wird', () {
    expect(row(appVersion: ' 1.23.1\n')['app_version'], '1.23.1');
  });

  test('Android and iOS render locally, web and desktop do not', () {
    // Web deliberately false: the service worker can do it but has never run —
    // and a fault there means NO notification at all any more.
    expect(row(platform: 'android')['local_render'], isTrue);
    expect(row(platform: 'ios')['local_render'], isTrue);
    expect(row(platform: 'web')['local_render'], isFalse);
    expect(row(platform: 'unknown')['local_render'], isFalse);
  });

  test('the timestamp is UTC and marked as such', () {
    // Without .toUtc() the timestamptz column reads a local time as UTC — the
    // row would then be misdated by the timezone offset, and that very date
    // later decides whether a device counts as "gone".
    expect(row()['updated_at'], '2026-08-13T22:30:00.000Z');
  });

  test('user, token and platform stand in it unchanged', () {
    final r = row(appVersion: '1.23.1');
    expect(r['user_id'], 'u1');
    expect(r['token'], 't1');
    expect(r['platform'], 'android');
  });

  group('a backend without 00076', () {
    // Chattr is self-hostable — "client newer than backend" is a real
    // constellation, not a slip in the deploy order. Then the row may be
    // written WITHOUT a version, rather than the device getting no
    // notifications at all.
    PostgrestException err(String code, String message) =>
        PostgrestException(message: message, code: code);

    test('an unknown column app_version is recognised', () {
      expect(
        DeviceTokenRepository.isUnknownColumn(
          err('PGRST204',
              "Could not find the 'app_version' column of 'device_tokens'"),
          'app_version',
        ),
        isTrue,
      );
    });

    test('a DIFFERENT missing column is not swallowed', () {
      // If `local_render` were missing, the second attempt would be just as
      // broken — that has to stand out, not pass silently.
      expect(
        DeviceTokenRepository.isUnknownColumn(
          err('PGRST204',
              "Could not find the 'local_render' column of 'device_tokens'"),
          'app_version',
        ),
        isFalse,
      );
    });

    test('a different error code does not count as a missing column', () {
      // 42501 = RLS/permissions. A second attempt would fail on it just the
      // same.
      expect(
        DeviceTokenRepository.isUnknownColumn(
          err('42501', 'permission denied for table device_tokens app_version'),
          'app_version',
        ),
        isFalse,
      );
    });
  });
}
