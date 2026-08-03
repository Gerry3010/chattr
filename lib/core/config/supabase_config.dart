// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Supabase Configuration
/// 
/// Diese Werte werden aus der .env Datei geladen
class SupabaseConfig {
  // Lokale Development URLs
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAndroidUrl => dotenv.env['SUPABASE_ANDROID_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  /// Basis-URL des Update-Endpoints. Der Android-Auto-Updater
  /// (`AndroidUpdateService`) fragt `$appDownloadBase/manifest.json` ab — das
  /// liefert der CMS-Versions-Endpoint (chattr.at) als latest-Release-Manifest;
  /// die APK ist ein Craft-Asset, das Manifest trägt eine absolute `apk_url`.
  /// Pro Plattform ein eigener Base (`.../android`, später `.../macos` …).
  static String get appDownloadBase =>
      (dotenv.env['APP_DOWNLOAD_BASE'] ??
              'https://chattr.at/api/updates/android')
          .replaceFirst(RegExp(r'/+$'), '');

  // Verhindere Instanziierung
  SupabaseConfig._();
}
