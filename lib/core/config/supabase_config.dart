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

  // Verhindere Instanziierung
  SupabaseConfig._();
}
