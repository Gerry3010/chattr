// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/updates/android_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = 'https://chattr.at/api/updates/android';

  group('AndroidUpdateInfo.tryParse', () {
    test('compares the versionCode, not the pubspec build_number', () {
      // The manifest carries both; the app must use version_code because that
      // is what PackageInfo.buildNumber returns on Android.
      final info = AndroidUpdateInfo.tryParse({
        'app_version': '1.9.3',
        'build_number': 34,
        'version_code': 2034,
        'apk_url': 'https://chattr.at/uploads/releases/chattr-android-2034.apk',
        'sha256': 'ABCDEF',
        'changelog_url': 'https://x/changelog',
      }, base);

      expect(info, isNotNull);
      expect(info!.appVersion, '1.9.3');
      expect(info.versionCode, 2034); // version_code, NOT build_number (34)
      expect(info.apkUrl,
          'https://chattr.at/uploads/releases/chattr-android-2034.apk');
      expect(info.sha256, 'ABCDEF');
      expect(info.changelogUrl, 'https://x/changelog');
    });

    test('regression: build_number vs versionCode scale mismatch', () {
      // The bug that shipped in build 2030: a build_number of 31 was compared
      // against the installed *versionCode* 2030, so 31 > 2030 was always false
      // and no update ever surfaced. With version_code, 2031 > 2030 fires.
      final info = AndroidUpdateInfo.tryParse(
          {'app_version': '1.10.0', 'build_number': 31, 'version_code': 2031},
          base)!;
      const installedVersionCode = 2030;
      expect(info.versionCode, 2031);
      expect(info.versionCode > installedVersionCode, isTrue); // update fires
      // The old (buggy) build_number comparison would NOT have fired:
      expect(31 > installedVersionCode, isFalse);
    });

    test('falls back to build_number when version_code is absent', () {
      final info =
          AndroidUpdateInfo.tryParse({'build_number': 34}, base)!;
      expect(info.versionCode, 34);
    });

    // CHAT-40: the manifest names the APK and its hash side by side, so
    // whoever controls the manifest picks both. The address at least has to
    // stay on our own host, over https.
    test('apk_url nur über https und vom eigenen Host', () {
      AndroidUpdateInfo? parse(String url) => AndroidUpdateInfo.tryParse(
          {'version_code': 2034, 'apk_url': url}, base);
      expect(parse('http://chattr.at/x.apk'), isNull);
      expect(parse('https://cdn.example/chattr.apk'), isNull);
      expect(parse('https://chattr.at.evil.example/x.apk'), isNull);
      expect(parse('https://downloads.chattr.at/x.apk'), isNotNull);
      expect(parse('https://chattr.at/uploads/x.apk'), isNotNull);
    });

    test('resolves a relative apk_url against the base', () {
      final info = AndroidUpdateInfo.tryParse(
          {'version_code': 2034, 'apk_url': 'chattr.apk'}, base);
      expect(info!.apkUrl, '$base/chattr.apk');
    });

    test('falls back to <base>/chattr.apk when apk_url is missing', () {
      final info = AndroidUpdateInfo.tryParse({'version_code': 2034}, base);
      expect(info!.apkUrl, '$base/chattr.apk');
    });

    test('accepts version_code as a string', () {
      final info =
          AndroidUpdateInfo.tryParse({'version_code': '2034'}, base);
      expect(info!.versionCode, 2034);
    });

    test('returns null when neither version_code nor build_number parses', () {
      expect(AndroidUpdateInfo.tryParse({'app_version': '1.0.0'}, base), isNull);
      expect(AndroidUpdateInfo.tryParse({'version_code': 'x1'}, base), isNull);
      expect(AndroidUpdateInfo.tryParse({'build_number': 'x1'}, base), isNull);
    });

    test('update decision is strictly-greater versionCode', () {
      final info =
          AndroidUpdateInfo.tryParse({'version_code': 2034}, base)!;
      expect(info.versionCode > 2033, isTrue);
      expect(info.versionCode > 2034, isFalse); // same → no update
      expect(info.versionCode > 2035, isFalse); // older manifest → no downgrade
    });
  });
}
