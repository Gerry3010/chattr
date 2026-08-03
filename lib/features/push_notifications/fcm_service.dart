// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/logging/logger_service.dart';

/// Top-level function for handling background messages
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  logger.info('Background message received: ${message.messageId}');
}

/// Service for managing Firebase Cloud Messaging
class FCMService {
  static final FCMService _instance = FCMService._internal();

  factory FCMService() => _instance;

  FCMService._internal();

  FirebaseMessaging? _messaging;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  bool _isInitialized = false;
  void Function(Map<String, dynamic>)? _onNotificationTapCallback;

  /// Tap data that arrived before [_onNotificationTapCallback] was registered
  /// (terminated-state launch); replayed by [setNotificationTapCallback].
  Map<String, dynamic>? _pendingTapData;

  /// Web Push (VAPID) public key for the Firebase project. Must match the
  /// "Web Push certificates" key pair in Firebase Console → Cloud Messaging.
  static const String _vapidKey =
      'BF_cZF3Kn9MYCK7R-HgPsqYd7Or_YuRntsumUHYmJdH3OANr7dmgSMQ9ReUSYvg4GqNCC5OPi41Mn383_5YHVkc';

  /// Firebase web options. On web, firebase_core requires explicit options
  /// passed to initializeApp() — it no longer adopts the JS-SDK app created in
  /// index.html. Mobile reads google-services.json / GoogleService-Info.plist
  /// natively, so it needs no options here. Values mirror web/index.html and
  /// web/firebase-messaging-sw.js (project your-firebase-project).
  static const FirebaseOptions _webOptions = FirebaseOptions(
    apiKey: 'YOUR_FIREBASE_API_KEY', // nosemgrep: detected-generic-api-key -- public Firebase Web config, not a secret
    authDomain: 'your-firebase-project.firebaseapp.com',
    projectId: 'your-firebase-project',
    storageBucket: 'your-firebase-project.firebasestorage.app',
    messagingSenderId: 'YOUR_MESSAGING_SENDER_ID',
    appId: 'YOUR_FIREBASE_APP_ID',
  );

  /// Stream of FCM tokens (initial + refreshes)
  Stream<String> get onTokenRefresh {
    if (_messaging == null) {
      throw StateError('FCM not initialized. Call initialize() first.');
    }
    return _messaging!.onTokenRefresh;
  }

  /// Current FCM token
  String? get token => _fcmToken;

  /// Whether FCM is initialized
  bool get isInitialized => _isInitialized;

  /// (Re-)fetch the FCM token on demand and cache it.
  ///
  /// The token is fetched once during [initialize], but that runs at startup —
  /// before the user has logged in or granted notification permission, so on
  /// web (and a fresh install) it is often null at that point. Login-time
  /// registration must therefore re-fetch rather than rely on the cached value.
  /// Returns null (and logs why) if the platform has no FCM or permission is
  /// still not granted.
  Future<String?> refreshToken() async {
    if (_messaging == null) {
      logger.warning('refreshToken: FCM not available on this platform');
      return null;
    }
    try {
      // On web, getToken only succeeds once notification permission is granted
      // and the service worker is active.
      final settings = await _messaging!.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        final requested = await _requestPermissions();
        if (requested.authorizationStatus != AuthorizationStatus.authorized) {
          logger.warning(
            'refreshToken: notification permission not granted '
            '(${requested.authorizationStatus})',
          );
          return null;
        }
      }

      _fcmToken = kIsWeb
          ? await _messaging!.getToken(vapidKey: _vapidKey)
          : await _messaging!.getToken();

      if (_fcmToken == null) {
        logger.warning('refreshToken: getToken returned null');
      } else {
        logger.info('refreshToken: token obtained '
            '(${_fcmToken!.substring(0, 12)}...)');
      }
      return _fcmToken;
    } catch (e, st) {
      logger.error('refreshToken failed', error: e, stackTrace: st);
      return null;
    }
  }

  /// Set callback for notification taps.
  ///
  /// If a tap arrived before the callback was registered (cold start: FCM
  /// init + getInitialMessage run in AppInit, the callback is only wired
  /// after auth via registerToken), replay the buffered tap now — otherwise
  /// a launch-from-notification never navigates.
  void setNotificationTapCallback(
      void Function(Map<String, dynamic>) callback) {
    _onNotificationTapCallback = callback;
    final pending = _pendingTapData;
    if (pending != null) {
      _pendingTapData = null;
      logger.info('Replaying buffered notification tap from cold start');
      callback(pending);
    }
  }

  /// Initialize FCM
  Future<void> initialize() async {
    if (_isInitialized) {
      logger.warning('FCM already initialized');
      return;
    }

    try {
      if (!kIsWeb && Platform.isLinux) {
        // Initialize only local notifications on Linux as Firebase is not supported on Linux
        unawaited(_initializeLocalNotifications());
        return;
      }
      // Initialize Firebase. Web requires explicit options; mobile reads its
      // native config files (google-services.json / GoogleService-Info.plist).
      if (kIsWeb) {
        await Firebase.initializeApp(options: _webOptions);
      } else {
        await Firebase.initializeApp();
      }
      logger.info('Firebase initialized');

      // Initialize FirebaseMessaging instance after Firebase.initializeApp
      _messaging = FirebaseMessaging.instance;

      final settings = await _requestPermissions();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        logger.warning('Notification permissions not granted');
      }

      // Initialize local notifications (not needed on web)
      if (!kIsWeb) {
        await _initializeLocalNotifications();
      }

      // Get FCM token (with VAPID key for web)
      if (kIsWeb) {
        _fcmToken = await _messaging!.getToken(vapidKey: _vapidKey);
      } else {
        _fcmToken = await _messaging!.getToken();
      }
      logger.info('FCM Token obtained: ${_fcmToken?.substring(0, 20)}...');

      // Set up message handlers
      _setupMessageHandlers();

      // Set foreground notification presentation options (iOS/web only; can
      // throw on platforms that don't support it — never fail init over it).
      // Alert/sound are OFF: while the app is foregrounded the in-app overlay
      // (NotificationController → InAppNotificationOverlay) is the only
      // notification surface; system banners would duplicate it.
      try {
        await _messaging!.setForegroundNotificationPresentationOptions(
          alert: false,
          badge: true,
          sound: false,
        );
      } catch (e) {
        logger.warning('setForegroundNotificationPresentationOptions failed: $e');
      }

      _isInitialized = true;
      logger.info('FCM initialized successfully');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to initialize FCM',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Request notification permissions
  Future<NotificationSettings> _requestPermissions() async {
    return _messaging!.requestPermission();
  }

  /// Initialize local notifications for foreground display
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linuxSettings = LinuxInitializationSettings(
        defaultActionName: 'Open App',
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      linux: linuxSettings,
    );

    await _localNotifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Create Android notification channel
    if (!kIsWeb && Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        'chattr_messages', // id
        'Messages', // name
        description: 'Notifications for new messages',
        importance: Importance.high,
        playSound: true,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);
    }
  }

  /// Set up message handlers
  void _setupMessageHandlers() {
    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Background message handler (set at top level). On web, background messages
    // are handled by web/firebase-messaging-sw.js, not a Dart isolate handler.
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }

    // Handle notification taps when app is in background/terminated
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // Check if app was opened from a terminated state via notification
    _checkInitialMessage();
  }

  /// Handle foreground messages.
  ///
  /// Deliberately does NOT show a notification: while the app is foregrounded
  /// the event-bus-driven in-app overlay is the single notification surface.
  /// Showing a local notification here (as this used to) produced a system
  /// banner on top of the in-app banner for every incoming message.
  /// Background/terminated pushes are unaffected — the OS renders the FCM
  /// `notification` block itself and taps arrive via onMessageOpenedApp /
  /// getInitialMessage.
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    logger.info(
      'Foreground message received (no banner, in-app overlay handles it): '
      '${message.messageId}',
    );
  }

  /// Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    logger.info('Notification tapped: ${message.messageId}');
    _processNotificationData(message.data);
  }

  /// Handle local notification tap
  void _onNotificationTap(NotificationResponse response) {
    logger.info('Local notification tapped: ${response.payload}');
    if (response.payload != null) {
      final data = _decodePayload(response.payload!);
      _processNotificationData(data);
    }
  }

  /// Check if app was opened from terminated state via notification
  Future<void> _checkInitialMessage() async {
    final message = await _messaging!.getInitialMessage();
    if (message != null) {
      logger.info('App opened from terminated state via notification');
      _handleNotificationTap(message);
    }
  }

  /// Process notification data and navigate accordingly
  void _processNotificationData(Map<String, dynamic> data) {
    debugPrint('[FCM] Processing notification data: $data');

    final callback = _onNotificationTapCallback;
    if (callback != null) {
      callback(data);
    } else {
      // Cold start: the navigation callback isn't wired yet (it's registered
      // after auth). Buffer the most recent tap for replay.
      _pendingTapData = data;
    }
  }

  /// Decode payload from local notifications (JSON; counterpart of the encode
  /// that lived in the removed foreground-banner path — kept because taps on
  /// notifications posted by older app versions can still deliver payloads).
  Map<String, dynamic> _decodePayload(String payload) {
    if (payload.isEmpty) return {};
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      logger.warning('Failed to decode notification payload: $e');
      return {};
    }
  }

  /// Subscribe to a topic
  Future<void> subscribeToTopic(String topic) async {
    try {
      await _messaging!.subscribeToTopic(topic);
      logger.info('Subscribed to topic: $topic');
    } catch (e) {
      logger.error('Failed to subscribe to topic: $topic', error: e);
    }
  }

  /// Unsubscribe from a topic
  Future<void> unsubscribeFromTopic(String topic) async {
    try {
      await _messaging!.unsubscribeFromTopic(topic);
      logger.info('Unsubscribed from topic: $topic');
    } catch (e) {
      logger.error('Failed to unsubscribe from topic: $topic', error: e);
    }
  }

  /// Clear every delivered notification from Notification Center / the system
  /// tray on app resume.
  ///
  /// Wired to app resume (and called once after init): pushes shown while the
  /// app was backgrounded accumulate in Notification Center and never clear
  /// themselves once the messages are read in-app. On iOS `cancelAll()` maps to
  /// `removeAllPendingNotificationRequests` + `removeAllDeliveredNotifications`,
  /// which also clears the system-rendered FCM remote notifications; on Android
  /// it clears the tray. Best-effort and mobile-only.
  ///
  /// The app-icon BADGE is intentionally NOT touched here anymore: it is owned
  /// by [appBadgeSyncProvider], which keeps it equal to the real unread total
  /// (the push `aps.badge` sets the same value while backgrounded). Forcing it
  /// to 0 on resume flashed a wrong count whenever unread chats remained.
  Future<void> clearDeliveredNotifications() async {
    if (kIsWeb) return;
    try {
      await _localNotifications.cancelAll();
    } catch (e) {
      logger.warning('clearDeliveredNotifications: cancelAll failed: $e');
    }
  }

  /// Delete FCM token
  Future<void> deleteToken() async {
    try {
      await _messaging!.deleteToken();
      _fcmToken = null;
      logger.info('FCM token deleted');
    } catch (e) {
      logger.error('Failed to delete FCM token', error: e);
    }
  }
}
