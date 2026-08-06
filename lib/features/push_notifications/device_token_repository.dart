// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/logging/logger_service.dart';

/// Repository for managing device tokens in Supabase
class DeviceTokenRepository {
  final SupabaseClient _supabase;

  DeviceTokenRepository(this._supabase);

  /// Save or update device token for current user
  Future<void> saveToken(String token) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        logger.warning('Cannot save token: user not authenticated');
        return;
      }

      final platform = _getPlatform();

      // Upsert token (insert or update if exists)
      await _supabase.from('device_tokens').upsert({
        'user_id': userId,
        'token': token,
        'platform': platform,
        // "Push ohne Klartext" (migration 00065): tells the server this build
        // can turn an id-only push into a readable notification by itself, so
        // it may stop sending the chat name and the sender's username through
        // Google. Written on every token refresh, which is also what upgrades
        // an existing row from the default FALSE.
        //
        // iOS says false on purpose: displaying a data-only push needs a
        // Notification Service Extension (stage 2). Claiming otherwise would
        // silence its notifications entirely.
        'local_render': _supportsLocalRender(platform),
        // .toUtc(): a naive local ISO string (no offset) would be read as UTC
        // by the timestamptz column, storing an instant off by the local offset.
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');

      logger.info('Device token saved for user $userId on $platform');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to save device token',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Delete device token
  Future<void> deleteToken(String token) async {
    try {
      await _supabase.from('device_tokens').delete().eq('token', token);
      logger.info('Device token deleted');
    } catch (e) {
      logger.error('Failed to delete device token', error: e);
    }
  }

  /// Delete all tokens for current user
  Future<void> deleteAllUserTokens() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        logger.warning('Cannot delete tokens: user not authenticated');
        return;
      }

      await _supabase.from('device_tokens').delete().eq('user_id', userId);
      logger.info('All device tokens deleted for user $userId');
    } catch (e) {
      logger.error('Failed to delete user tokens', error: e);
    }
  }

  /// Get all tokens for current user
  Future<List<Map<String, dynamic>>> getUserTokens() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        logger.warning('Cannot get tokens: user not authenticated');
        return [];
      }

      final response = await _supabase
          .from('device_tokens')
          .select()
          .eq('user_id', userId);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      logger.error('Failed to get user tokens', error: e);
      return [];
    }
  }

  /// Get platform string
  String _getPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Platforms where THIS build renders the notification itself.
  ///
  /// Android does it in `firebaseMessagingBackgroundHandler`, web in
  /// `web/firebase-messaging-sw.js`. Both ship together with this line, so a
  /// device only ever claims the capability it actually has.
  ///
  /// A browser still running an older cached service worker degrades to a
  /// generic "Chattr / New message" rather than silence — that worker's own
  /// fallbacks catch a payload without title/body — and it picks up the new
  /// one on the next navigation.
  static bool _supportsLocalRender(String platform) =>
      platform == 'android' || platform == 'ios';
  // iOS ist seit der Notification Service Extension dabei (am iPhone
  // verifiziert, 2026-08-05). Ein Versions-Gate braucht es nicht: Flag und
  // Extension liegen im SELBEN Binary, es kann also keinen Client geben, der
  // sich als render-fähig meldet und keine Extension hat. Ältere Builds kennen
  // das Feld gar nicht und bleiben auf dem Standard FALSE.
  //
  // Web ist BEWUSST weiter nicht dabei, obwohl der Service Worker den Renderer
  // mitbringt: dieser Pfad ist auf keinem Browser je durchgelaufen. Und die
  // Fehlerwirkung ist hier die schlimmste von allen — anders als iOS, das
  // immer einen alert-Block bekommt und schlimmstenfalls den Platzhalter
  // zeigt, bekäme ein Browser GAR KEINE Benachrichtigung mehr. Die Zeile
  // umzustellen ist Sekundenarbeit, sobald es jemand einmal gesehen hat.
  //
  // ACHTUNG bei künftigen Änderungen: eine bestehende Zeile behält ihren Wert,
  // wenn ein Client das Feld nicht mitschickt. Eine Einschränkung hier wirkt
  // deshalb NICHT rückwirkend — vier Web-Zeilen standen dadurch noch auf TRUE,
  // nachdem Web ausgenommen war (2026-08-05 von Hand aufgeräumt).
}
