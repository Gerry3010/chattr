// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Version Service
///
/// Manages app versioning and backend compatibility checks
class VersionService {
  static VersionService? _instance;
  PackageInfo? _packageInfo;
  Map<String, dynamic>? _backendVersions;
  DateTime? _lastCheck;

  VersionService._();

  /// Get singleton instance
  static VersionService get instance {
    _instance ??= VersionService._();
    return _instance!;
  }

  /// Initialize the service
  Future<void> initialize() async {
    _packageInfo = await PackageInfo.fromPlatform();
  }

  /// Get app version string (e.g. "1.0.0")
  String getAppVersion() {
    return _packageInfo?.version ?? 'Unknown';
  }

  /// Get build number (e.g. "1")
  String getBuildNumber() {
    return _packageInfo?.buildNumber ?? 'Unknown';
  }

  /// Get full version string (e.g. "1.0.0+1")
  String getFullVersion() {
    return '${getAppVersion()}+${getBuildNumber()}';
  }

  /// Get package name
  String getPackageName() {
    return _packageInfo?.packageName ?? 'Unknown';
  }

  /// Get app name
  String getAppName() {
    return _packageInfo?.appName ?? 'Chattr';
  }

  /// Fetch backend version from Supabase
  Future<Map<String, dynamic>?> getBackendVersion({bool forceRefresh = false}) async {
    // Use cached version if available and fresh (< 5 minutes old)
    if (!forceRefresh &&
        _backendVersions != null &&
        _lastCheck != null &&
        DateTime.now().difference(_lastCheck!) < const Duration(minutes: 5)) {
      return _backendVersions;
    }

    try {
      final supabase = Supabase.instance.client;
      final response = await supabase.rpc<dynamic>('get_backend_version');

      if (response is List && response.isNotEmpty) {
        _backendVersions = response.first as Map<String, dynamic>;
        _lastCheck = DateTime.now();
        return _backendVersions;
      }

      return null;
    } catch (e) {
      debugPrint('Error fetching backend version: $e');
      return null;
    }
  }

  /// Get all component versions from Supabase
  Future<List<Map<String, dynamic>>?> getAllVersions() async {
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase.rpc<dynamic>('get_all_versions');

      if (response is List) {
        return response.cast<Map<String, dynamic>>();
      }

      return null;
    } catch (e) {
      debugPrint('Error fetching all versions: $e');
      return null;
    }
  }

  /// Compare version strings (returns -1 if v1 < v2, 0 if equal, 1 if v1 > v2)
  int compareVersions(String v1, String v2) {
    final parts1 = v1.split('.').map(int.parse).toList();
    final parts2 = v2.split('.').map(int.parse).toList();

    for (int i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 < p2) return -1;
      if (p1 > p2) return 1;
    }

    return 0;
  }

  /// Check if the current client is compatible with the backend
  Future<VersionCompatibility> checkBackendCompatibility({
    String minBackendVersion = '1.0.0',
  }) async {
    final backendVersion = await getBackendVersion();

    if (backendVersion == null) {
      return VersionCompatibility(
        isCompatible: false,
        reason: 'Could not fetch backend version',
        recommendation: 'Check your internet connection and try again',
      );
    }

    final currentBackendVersion = backendVersion['version'] as String;
    final comparison = compareVersions(currentBackendVersion, minBackendVersion);

    if (comparison < 0) {
      return VersionCompatibility(
        isCompatible: false,
        reason: 'Backend version $currentBackendVersion is older than required $minBackendVersion',
        recommendation: 'Please contact support. The server needs to be updated.',
      );
    }

    return VersionCompatibility(
      isCompatible: true,
      backendVersion: currentBackendVersion,
    );
  }

  /// Show update dialog if incompatible
  Future<void> showUpdateDialog(
    BuildContext context, {
    required String title,
    required String message,
    required String actionLabel,
    VoidCallback? onAction,
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (onAction != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onAction();
              },
              child: Text(actionLabel),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Format timestamp to readable date
  String formatDeployedAt(String? timestamp) {
    if (timestamp == null) return 'Unknown';
    
    try {
      final dateTime = DateTime.parse(timestamp);
      return '${dateTime.day}.${dateTime.month}.${dateTime.year} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return timestamp;
    }
  }
}

/// Version compatibility result
class VersionCompatibility {
  final bool isCompatible;
  final String? reason;
  final String? recommendation;
  final String? backendVersion;

  VersionCompatibility({
    required this.isCompatible,
    this.reason,
    this.recommendation,
    this.backendVersion,
  });
}
