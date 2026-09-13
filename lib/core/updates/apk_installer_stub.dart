// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Outcome of an APK download+install attempt.
class ApkInstallResult {
  /// True if the system package installer was handed the APK.
  final bool launched;

  /// Non-null describes why it didn't launch (for logging + fallback).
  final String? error;

  const ApkInstallResult({required this.launched, this.error});
}

/// Web/no-io stub — sideloading an APK only exists on native Android.
Future<ApkInstallResult> downloadAndInstallApk({
  required String url,
  String? expectedSha256,
  required void Function(double progress) onProgress,
  void Function()? onVerifying,
}) async =>
    const ApkInstallResult(launched: false, error: 'unsupported platform');
