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
        // .toUtc(): a naive local ISO string (no offset) would be read as UTC
        // by the timestamptz column, storing an instant off by the local offset.
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');

      logger.info('Device token saved for user $userId on $platform');
    } catch (e, stackTrace) {
      logger.error('Failed to save device token', error: e, stackTrace: stackTrace);
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
}
