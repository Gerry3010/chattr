// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chattr/features/about/changelog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseChangelog', () {
    test('splits releases and keeps their bodies', () {
      final r = parseChangelog('''
# Changelog

## [Unreleased]

## [1.12.0] - 2026-08-03

### Added
- Erstes

### Fixed
- Zweites

## [1.11.3] - 2026-08-02

### Security
- Drittes
''');

      expect(r.map((e) => e.version), ['1.12.0', '1.11.3']);
      expect(r.first.date, '2026-08-03');
      expect(r.first.body, contains('Erstes'));
      expect(r.first.body, contains('Zweites'));
      // The body must NOT run over into the next release.
      expect(r.first.body, isNot(contains('Drittes')));
      expect(r.last.body, contains('Drittes'));
    });

    test('drops an empty Unreleased marker but keeps one with content', () {
      expect(parseChangelog('## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n- x')
          .map((e) => e.version), ['1.0.0']);

      final withContent =
          parseChangelog('## [Unreleased]\n\n- kommt noch\n\n## [1.0.0] - 2026-01-01\n- x');
      expect(withContent.map((e) => e.version), ['Unreleased', '1.0.0']);
      expect(withContent.first.isUnreleased, isTrue);
      expect(withContent.first.date, isNull);
    });

    test('survives a heading without a date', () {
      final r = parseChangelog('## [2.0.0]\n\n- ohne Datum');
      expect(r.single.version, '2.0.0');
      expect(r.single.date, isNull);
      expect(r.single.body, '- ohne Datum');
    });

    test('returns nothing for a document without version headings', () {
      expect(parseChangelog('# Changelog\n\nNur Fließtext.'), isEmpty);
    });
  });

  group('the real CHANGELOG.md', () {
    // The screen renders exactly this file. A format break while maintaining
    // the changelog would otherwise only show up on the device — as an empty
    // screen.
    final text = File('CHANGELOG.md').readAsStringSync();
    final releases = parseChangelog(text);

    test('parses and has entries', () {
      expect(releases, isNotEmpty);
      expect(releases.length, greaterThan(3));
    });

    test('every entry has content and a date', () {
      for (final r in releases.where((e) => !e.isUnreleased)) {
        expect(r.body, isNotEmpty, reason: '${r.version} hat einen leeren Body');
        expect(r.date, isNotNull, reason: '${r.version} hat kein Datum');
      }
    });

    test('is registered as an asset — otherwise the screen loads into nothing', () {
      expect(File('pubspec.yaml').readAsStringSync(), contains('- CHANGELOG.md'));
    });
  });
}
