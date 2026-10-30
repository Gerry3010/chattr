// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/logging/logger_service.dart';

/// Repository for managing device tokens in Supabase
class DeviceTokenRepository {
  final SupabaseClient _supabase;
  final Future<String?> Function() _readAppVersion;

  DeviceTokenRepository(
    this._supabase, {
    Future<String?> Function()? readAppVersion,
  }) : _readAppVersion = readAppVersion ?? _packageVersion;

  /// The installed version ("1.23.1"), or null if this platform will not say.
  ///
  /// Swallows its own failure on purpose: the version is a nice-to-have for a
  /// rollout gate, while the token is what makes notifications arrive at all.
  /// A missing plugin registration must not cost a device its push.
  static Future<String?> _packageVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version.trim();
    } catch (e) {
      logger.warning('Could not read app version for device token: $e');
      return null;
    }
  }

  /// The row that goes to the server for one device.
  ///
  /// Separated from the call because every field here is a statement ABOUT the
  /// device that the server then acts on — get one wrong and a real phone goes
  /// silent or gets counted into the wrong rollout bucket.
  @visibleForTesting
  static Map<String, dynamic> tokenRow({
    required String userId,
    required String token,
    required String platform,
    String? appVersion,
    DateTime? now,
  }) {
    return {
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
      // Rollout gate (migration 00076): several server-side changes may only
      // land once no old client is left — 00075 (private avatar buckets) would
      // blank out every picture on a build before 1.22.0, and 00063 still
      // double-sends every message so pre-private-channel clients keep working.
      // Without this line "is the fleet through?" is a guess, and a wrong guess
      // costs real users their pictures or their notifications.
      //
      // Version only, no device model, no OS build: what the decision needs,
      // nothing beyond it. A version this device cannot name is left out
      // entirely rather than sent as a placeholder — the server reads NULL as
      // "old", and an invented value would read as "new".
      if (appVersion != null && appVersion.trim().isNotEmpty)
        'app_version': appVersion.trim(),
      // .toUtc(): a naive local ISO string (no offset) would be read as UTC
      // by the timestamptz column, storing an instant off by the local offset.
      'updated_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    };
  }

  /// Does this error say "I have never heard of that column"?
  ///
  /// PostgREST answers a missing column with PGRST204 and names it in the
  /// message. Both are checked: the code alone would also swallow a different
  /// column going missing, which is a real problem that should surface.
  @visibleForTesting
  static bool isUnknownColumn(PostgrestException e, String column) =>
      e.code == 'PGRST204' && e.message.contains(column);

  /// Save or update device token for current user. [platform] overrides the
  /// detected one — for the iOS PushKit token, which is a token of its own
  /// kind ('ios_voip', 00088): APNs-only, and never for an ordinary push.
  Future<void> saveToken(String token, {String? platform}) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        logger.warning('Cannot save token: user not authenticated');
        return;
      }

      final kind = platform ?? _getPlatform();
      final appVersion = await _readAppVersion();

      // Upsert token (insert or update if exists)
      var wroteVersion = appVersion != null;
      try {
        await _supabase.from('device_tokens').upsert(
              tokenRow(
                userId: userId,
                token: token,
                platform: kind,
                appVersion: appVersion,
              ),
              onConflict: 'token',
            );
      } on PostgrestException catch (e) {
        // A backend without migration 00076 does not know `app_version` and
        // rejects the whole row. That must not cost this device its push: the
        // column exists for OUR convenience in judging a rollout, while the
        // row exists so notifications arrive at all. Chattr is self-hostable,
        // so "client newer than backend" is a real configuration, not just a
        // deployment-order slip.
        if (!wroteVersion || !isUnknownColumn(e, 'app_version')) rethrow;
        logger.warning(
          'Backend does not know device_tokens.app_version (migration 00076 '
          'missing) — saving the token without it.',
        );
        wroteVersion = false;
        await _supabase.from('device_tokens').upsert(
              tokenRow(
                userId: userId,
                token: token,
                platform: kind,
              ),
              onConflict: 'token',
            );
      }

      logger.info(
        'Device token saved for user $userId on $kind'
        '${wroteVersion ? ' (v$appVersion)' : ''}',
      );
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
  // iOS has been included since the Notification Service Extension (verified on
  // the iPhone, 2026-08-05). No version gate is needed: the flag and the
  // extension sit in the SAME binary, so there can be no client reporting
  // itself render-capable without an extension. Older builds do not know the
  // field at all and stay on the default FALSE.
  //
  // Web is DELIBERATELY still excluded, although the service worker brings the
  // renderer along: this path has never once run through on any browser. And
  // the failure effect is the worst of all here — unlike iOS, which always gets
  // an alert block and at worst shows the placeholder, a browser would get NO
  // notification at all any more. Flipping the line is seconds of work once
  // somebody has seen it work once.
  //
  // CAUTION with future changes: an existing row keeps its value when a client
  // does not send the field. A restriction here therefore does NOT apply
  // retroactively — four web rows were still on TRUE after web had been
  // excluded (cleaned up by hand on 2026-08-05).
}
