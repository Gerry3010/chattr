// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Outcome of an APK download+install attempt.
class ApkInstallResult {
  /// True if the system package installer was handed the APK.
  final bool launched;

  /// Non-null describes why it didn't launch (for logging + fallback).
  final String? error;

  const ApkInstallResult({required this.launched, this.error});
}

const _apkMime = 'application/vnd.android.package-archive';

/// Download the APK to app cache (streaming, with progress), verify its
/// SHA-256 if the manifest provided one, then open it with the system package
/// installer. The user still confirms the install in the OS prompt — this only
/// gets them there.
Future<ApkInstallResult> downloadAndInstallApk({
  required String url,
  String? expectedSha256,
  required void Function(double progress) onProgress,
  void Function()? onVerifying,
}) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    final resp =
        await client.send(req).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      return ApkInstallResult(launched: false, error: 'HTTP ${resp.statusCode}');
    }

    final total = resp.contentLength ?? 0;
    final bytes = <int>[];
    var received = 0;
    await for (final chunk in resp.stream) {
      bytes.addAll(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total);
    }

    // Integrity gate: a tampered/truncated APK never reaches the installer.
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      onVerifying?.call();
      final actual = sha256.convert(bytes).toString();
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        return const ApkInstallResult(
            launched: false, error: 'sha256 mismatch');
      }
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/chattr-update.apk');
    await file.writeAsBytes(bytes, flush: true);

    final open = await OpenFilex.open(file.path, type: _apkMime);
    final launched = open.type == ResultType.done;
    return ApkInstallResult(
      launched: launched,
      error: launched ? null : '${open.type}: ${open.message}',
    );
  } catch (e) {
    return ApkInstallResult(launched: false, error: '$e');
  } finally {
    client.close();
  }
}
