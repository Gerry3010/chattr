// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Supabase Configuration
///
/// These values are loaded from the .env file.
class SupabaseConfig {
  // Lokale Development URLs
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAndroidUrl => dotenv.env['SUPABASE_ANDROID_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  /// Base URL of the update endpoint. The Android auto-updater
  /// (`AndroidUpdateService`) queries `$appDownloadBase/manifest.json` — that
  /// is served by the CMS version endpoint (chattr.at) as the latest-release
  /// manifest; the APK is a Craft asset, and the manifest carries an absolute
  /// `apk_url`. One base per platform (`.../android`, later `.../macos` …).
  static String get appDownloadBase =>
      (dotenv.env['APP_DOWNLOAD_BASE'] ??
              'https://chattr.at/api/updates/android')
          .replaceFirst(RegExp(r'/+$'), '');

  // Verhindere Instanziierung
  SupabaseConfig._();
}
