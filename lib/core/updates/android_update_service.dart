// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config/supabase_config.dart';
import '../lifecycle/app_lifecycle_service.dart';
import '../logging/logger_service.dart';
import 'apk_installer.dart';

/// True only on a real Android device (never web) — the only platform that
/// sideloads an APK. iOS ships via App Store/TestFlight, web reloads (see
/// [WebUpdateService]), desktop is out of scope.
bool get isAndroidUpdateTarget =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// A newer build advertised by the download host's `manifest.json`.
class AndroidUpdateInfo {
  final String appVersion;

  /// The Android **versionCode** of the advertised APK. This is what is compared
  /// against the installed build — and `PackageInfo.buildNumber` returns the
  /// versionCode on Android, so both sides are the same scale.
  final int versionCode;
  final String apkUrl;
  final String? sha256;
  final String? changelogUrl;

  const AndroidUpdateInfo({
    required this.appVersion,
    required this.versionCode,
    required this.apkUrl,
    this.sha256,
    this.changelogUrl,
  });

  /// Parse a manifest map, resolving a relative `apk_url` against [base].
  /// Returns null if the payload lacks the fields we need.
  static AndroidUpdateInfo? tryParse(
    Map<String, dynamic> json,
    String base,
  ) {
    // Compare the Android *versionCode* (what PackageInfo.buildNumber returns on
    // Android) — NOT the pubspec `build_number`. They are different scales:
    // e.g. build_number 31 vs versionCode 2031 (the +2000 arm64 `--split-per-abi`
    // offset), so comparing `build_number` against the installed versionCode
    // never fires. Fall back to `build_number` only if a manifest omits it.
    final code = _asInt(json['version_code']) ?? _asInt(json['build_number']);
    if (code == null) return null;
    final rawApk = (json['apk_url'] as String?)?.trim();
    final apkUrl = (rawApk == null || rawApk.isEmpty)
        ? '$base/chattr.apk'
        : (rawApk.startsWith('http') ? rawApk : '$base/$rawApk');
    return AndroidUpdateInfo(
      appVersion: (json['app_version'] as String?)?.trim() ?? '',
      versionCode: code,
      apkUrl: apkUrl,
      sha256: (json['sha256'] as String?)?.trim(),
      changelogUrl: (json['changelog_url'] as String?)?.trim(),
    );
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v.trim());
    if (v is double) return v.toInt();
    return null;
  }
}

/// Set to the newer build once a check finds one; the listener surfaces a
/// banner. Null means "no update pending".
final androidUpdateAvailableProvider =
    StateProvider<AndroidUpdateInfo?>((ref) => null);

/// Phases of the (optional) in-app download+install the user can trigger from
/// the banner. Drives the progress UI in [AndroidUpdateListener].
enum AndroidUpdatePhase { idle, downloading, verifying, launching, failed }

class AndroidUpdateProgress {
  final AndroidUpdatePhase phase;

  /// 0..1 during [AndroidUpdatePhase.downloading]; ignored otherwise.
  final double progress;

  const AndroidUpdateProgress(this.phase, [this.progress = 0]);

  static const idle = AndroidUpdateProgress(AndroidUpdatePhase.idle);
}

final androidUpdateProgressProvider =
    StateProvider<AndroidUpdateProgress>((ref) => AndroidUpdateProgress.idle);

/// Session-lifetime service; started once by the UI listener widget.
final androidUpdateServiceProvider = Provider<AndroidUpdateService>((ref) {
  final service = AndroidUpdateService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Auto-update detection for the sideloaded Android APK.
///
/// There is no Play Store for this channel, so the app has to notice a newer
/// APK itself. This mirrors [WebUpdateService]: fetch a small manifest at
/// startup / on an interval / on every resume, compare its `build_number`
/// against this build's, and — when the manifest is newer — offer the update.
/// Unlike the web path (which just reloads), Android downloads the APK and
/// hands it to the system installer, with a browser download as the fallback.
class AndroidUpdateService {
  final Ref _ref;
  final http.Client _client;
  Timer? _timer;
  StreamSubscription<void>? _resumeSub;
  bool _started = false;
  int? _currentBuild;

  static const _checkInterval = Duration(hours: 6);

  AndroidUpdateService(this._ref, {http.Client? client})
      : _client = client ?? http.Client();

  void start() {
    if (!isAndroidUpdateTarget || _started) return;
    _started = true;
    unawaited(checkNow());
    _timer = Timer.periodic(_checkInterval, (_) => checkNow());
    _resumeSub = _ref
        .read(appLifecycleServiceProvider)
        .onResume
        .listen((_) => checkNow());
  }

  /// One manifest probe. Public for tests; production goes through [start].
  @visibleForTesting
  Future<void> checkNow() async {
    try {
      final base = SupabaseConfig.appDownloadBase;
      // Cache-buster so a CDN/proxy never pins a stale manifest.
      final uri = Uri.parse(
        '$base/manifest.json?u=${DateTime.now().millisecondsSinceEpoch}',
      );
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final info = AndroidUpdateInfo.tryParse(data, base);
      if (info == null) return;

      // On Android, PackageInfo.buildNumber IS the installed versionCode.
      final current = _currentBuild ??=
          int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

      if (info.versionCode > current) {
        logger.info(
          'Android update available: versionCode $current -> ${info.versionCode}',
          tag: 'AndroidUpdate',
        );
        _ref.read(androidUpdateAvailableProvider.notifier).state = info;
      }
    } catch (e) {
      // Offline or server hiccup — try again next interval.
      logger.debug('Android update check failed: $e');
    }
  }

  /// Download the APK (with progress), verify its hash, and hand it to the
  /// system installer. Returns true if the installer was launched; on any
  /// failure sets [AndroidUpdatePhase.failed] and returns false so the caller
  /// can offer the browser fallback.
  Future<bool> downloadAndInstall(AndroidUpdateInfo info) async {
    final progress = _ref.read(androidUpdateProgressProvider.notifier);
    try {
      progress.state =
          const AndroidUpdateProgress(AndroidUpdatePhase.downloading, 0);
      final result = await downloadAndInstallApk(
        url: info.apkUrl,
        expectedSha256: info.sha256,
        onProgress: (p) => progress.state =
            AndroidUpdateProgress(AndroidUpdatePhase.downloading, p),
        onVerifying: () => progress.state =
            const AndroidUpdateProgress(AndroidUpdatePhase.verifying),
      );
      if (!result.launched) {
        progress.state =
            const AndroidUpdateProgress(AndroidUpdatePhase.failed);
        logger.info('APK install not launched: ${result.error}',
            tag: 'AndroidUpdate');
        return false;
      }
      progress.state =
          const AndroidUpdateProgress(AndroidUpdatePhase.launching);
      return true;
    } catch (e) {
      progress.state = const AndroidUpdateProgress(AndroidUpdatePhase.failed);
      logger.warning('APK download/install failed: $e', tag: 'AndroidUpdate');
      return false;
    }
  }

  /// Reset the download UI back to idle (e.g. user dismissed the error).
  void resetProgress() =>
      _ref.read(androidUpdateProgressProvider.notifier).state =
          AndroidUpdateProgress.idle;

  void dispose() {
    _timer?.cancel();
    _resumeSub?.cancel();
    _client.close();
  }
}
