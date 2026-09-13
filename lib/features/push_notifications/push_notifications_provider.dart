// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import 'device_token_repository.dart';
import 'fcm_service.dart';
import 'notification_navigation_handler.dart';

/// Provider for FCM service
final fcmServiceProvider = Provider<FCMService>((ref) {
  return FCMService();
});

/// Provider for device token repository
final deviceTokenRepositoryProvider = Provider<DeviceTokenRepository>((ref) {
  return DeviceTokenRepository(Supabase.instance.client);
});

/// Provider for managing push notification initialization and token management
final pushNotificationsManagerProvider = Provider<PushNotificationsManager>((
  ref,
) {
  return PushNotificationsManager(
    ref.read(fcmServiceProvider),
    ref.read(deviceTokenRepositoryProvider),
    ref.read(notificationNavigationHandlerProvider),
    ref.read(appLifecycleServiceProvider),
  );
});

/// Manager for coordinating FCM and token repository
class PushNotificationsManager {
  final FCMService _fcmService;
  final DeviceTokenRepository _tokenRepository;
  final NotificationNavigationHandler _navigationHandler;
  final AppLifecycleService _lifecycleService;

  PushNotificationsManager(
    this._fcmService,
    this._tokenRepository,
    this._navigationHandler,
    this._lifecycleService,
  );

  bool _sessionWired = false;
  StreamSubscription<void>? _resumeSub;

  /// Wires the pieces that must run once per app session regardless of HOW
  /// the session came to be (fresh login or restored): the notification-tap
  /// deep-link callback and the token-refresh listener. Idempotent.
  ///
  /// This used to live in an initialize() method that nothing ever called —
  /// AppInit talks to FCMService directly — so tap navigation and refresh
  /// persistence were silently dead. Hooked into [registerToken] instead,
  /// which both session paths go through.
  void _wireSession() {
    if (_sessionWired) return;
    _sessionWired = true;
    _fcmService.setNotificationTapCallback(
      _navigationHandler.handleNotificationTap,
    );

    // Clear any notifications that piled up while the app was gone, every time
    // it returns to the foreground — plus once right now, for the launch that
    // opened straight into a restored session. Best-effort; the FCMService call
    // swallows its own errors.
    _resumeSub ??= _lifecycleService.onResume.listen((_) {
      unawaited(_fcmService.clearDeliveredNotifications());
    });
    unawaited(_fcmService.clearDeliveredNotifications());

    // No FCM on this platform (e.g. Linux desktop) — accessing onTokenRefresh
    // would throw.
    if (!_fcmService.isInitialized) return;
    _fcmService.onTokenRefresh.listen((newToken) async {
      try {
        await _tokenRepository.saveToken(newToken);
        logger.info('FCM token refresh persisted');
      } catch (e) {
        logger.error('Failed to persist refreshed FCM token', error: e);
      }
    });
  }

  /// Register (or re-sync) the device token. Called after a fresh login AND
  /// on every app start with a restored session.
  ///
  /// The restored-session call matters: the token can rotate — or remap its
  /// APNs environment after a rebuild — while the server row keeps the stale
  /// value, and nothing else would ever update it (login-only registration
  /// was why a stale prod-mapped iOS token never healed itself).
  ///
  /// Re-fetches the token rather than trusting the value cached at startup:
  /// FCM init runs before login / permission grant, so on web (and fresh
  /// installs) the startup token is usually null. A null here is not an error —
  /// the platform may simply lack FCM (Linux desktop) or permission was denied.
  Future<void> registerToken() async {
    _wireSession();
    final token = _fcmService.token ?? await _fcmService.refreshToken();
    if (token != null) {
      await _tokenRepository.saveToken(token);
      logger.info('Device token saved (${token.substring(0, 12)}...)');
    } else {
      logger.warning(
        'registerToken: no FCM token available (no permission / no FCM on '
        'this platform) — skipping device-token registration',
      );
    }
  }

  /// Unregister device token on logout
  Future<void> unregisterToken() async {
    final token = _fcmService.token;
    if (token != null) {
      await _tokenRepository.deleteToken(token);
    }
    await _fcmService.deleteToken();
  }

  /// Unregister all user tokens
  Future<void> unregisterAllTokens() async {
    await _tokenRepository.deleteAllUserTokens();
  }
}
