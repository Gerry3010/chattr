// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/logging/logger_service.dart';
import '../calls/call_system_ui.dart';
import 'push_local_renderer.dart';
import 'push_render_cache.dart';

/// Status-bar icon for every local notification, foreground and background.
///
/// A DRAWABLE resource name, verbatim and WITHOUT a `@type/` prefix — the
/// plugin resolves it with `getIdentifier(name, "drawable", package)` and looks
/// nowhere else. `'@mipmap/ic_launcher'` therefore failed twice over (wrong
/// resource type, prefix not stripped): `initialize()` threw `invalid_icon`,
/// and Android was left with NO local notifications at all.
///
/// It is a constant rather than two literals because it is initialised in two
/// places that never see each other — the app, and the background isolate FCM
/// spawns. Fixing only one of them is exactly the bug that shipped: the push
/// arrived, the isolate woke, and died on this call without showing anything.
const String notificationIcon = 'ic_stat_chattr';

/// Top-level function for handling background messages.
///
/// Since "Push ohne Klartext" (migration 00065) a push to this device carries
/// only ids, and with no `notification` block Android shows nothing by itself —
/// building the notification IS this handler's job now, not a side note.
///
/// Runs in its own isolate: no Riverpod, no AppInit, no EasyLocalization. It
/// gets by on SharedPreferences ([PushRenderCache]), which the foreground app
/// keeps stocked with names and localized wording.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // A background isolate starts with no plugin registrations of its own —
  // without this, SharedPreferences and flutter_local_notifications throw
  // MissingPluginException and the user simply gets no notification.
  DartPluginRegistrant.ensureInitialized();

  // A call (stage 3, 00088): no tray entry — the system's incoming-call UI.
  if (isCallPushData(message.data)) {
    try {
      await handleCallPushInBackground(message.data);
    } catch (e, st) {
      debugPrint('Incoming call UI failed: $e\n$st');
    }
    return;
  }

  // A push that still carries a `notification` block was rendered by the OS
  // before we ever ran (an older payload, or iOS). Rendering it again would
  // show it twice.
  if (message.notification != null) return;

  try {
    await showLocallyRenderedPush(message.data);
  } catch (e, st) {
    // Never let this isolate die on the way to the tray: a thrown exception
    // here is indistinguishable from a broken push pipeline for the user.
    debugPrint('Local push rendering failed: $e\n$st');
  }
}

/// Build and post the notification for an id-only push.
///
/// Separate from the handler so a test can drive it, and so the foreground
/// path could reuse it if it ever needs to.
Future<void> showLocallyRenderedPush(Map<String, dynamic> data) async {
  final cached = await PushRenderCache.read();
  debugPrint('[push] isolate read ${cached.names.length} cached names');
  final rendered = renderPush(
    data,
    names: cached.names,
    templates: cached.templates,
  );
  // Unknown notification type — deliberately quiet, see renderPush.
  if (rendered == null) return;

  final plugin = FlutterLocalNotificationsPlugin();
  // The SECOND initialize in this file, and it needs the same icon as the
  // first: the background isolate is a fresh Dart VM with no memory of what
  // the foreground app configured. Fixing only the foreground one left this
  // call throwing `invalid_icon` — the push arrived, the isolate woke, and
  // then died right here without showing anything (Galaxy log, 2026-08-04).
  // See [notificationIcon] for why the name has no `@mipmap/` prefix.
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings(notificationIcon),
    ),
  );

  await plugin.show(
    id: rendered.notificationId,
    title: rendered.title,
    body: rendered.body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        // Same channel the foreground service creates, so the user's per-
        // channel sound and importance settings apply to both paths.
        'chattr_messages',
        'Messages',
        channelDescription: 'Notifications for new messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    // Carries the ids through to the tap handler, which navigates by chat_id.
    payload: jsonEncode(data),
  );
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
    // The key belongs here: a Firebase web configuration is public, it sits in
    // every shipped web app and is secured through Firebase rules and key
    // restrictions, not through secrecy. Mirrors web/index.html.
    //
    // Until 2026-08-21 the suppression stood as an end-of-line comment BEHIND
    // the value — and did not take: Semgrep anchors the finding at the START of
    // the match (`apiKey:`), so one line above. The weekly scan therefore
    // reported the same HIGH finding every week. An alarm that always goes off
    // and is always wrong teaches one to skip the whole report.
    //
    // Both suppressions below are DIRECTIVES, not prose, and both are
    // position-sensitive in a different way: semgrep wants its rule id on the
    // SAME line as `nosemgrep:`, gitleaks wants `gitleaks:allow` on the same
    // line as the VALUE. Each is over 80 columns on purpose. A translation
    // pass re-wrapped the semgrep one on 2026-09-12 and silently disarmed it —
    // the exact failure this comment was written about in the first place.
    // Do not reflow them.
    // nosemgrep: generic.secrets.security.detected-generic-api-key.detected-generic-api-key
    apiKey: 'YOUR_FIREBASE_API_KEY', // gitleaks:allow
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
        logger.info(
          'refreshToken: token obtained '
          '(${_fcmToken!.substring(0, 12)}...)',
        );
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
    void Function(Map<String, dynamic>) callback,
  ) {
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

      // The token is fetched behind the start, not before it (CHAT-63).
      // getToken needs the network: offline it held the splash screen up to
      // the 8 s deadline, and when it threw, initialize() stopped right here,
      // so the message handlers below were never set up for the whole
      // session. registerToken() asks again when it needs the token.
      unawaited(_fetchInitialToken());

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
        logger.warning(
          'setForegroundNotificationPresentationOptions failed: $e',
        );
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

  Future<void> _fetchInitialToken() async {
    try {
      final token = kIsWeb
          ? await _messaging!.getToken(vapidKey: _vapidKey)
          : await _messaging!.getToken();
      _fcmToken ??= token;
      logger.info('FCM Token obtained: ${token?.substring(0, 20)}...');
    } catch (e) {
      logger.warning('FCM token not available yet (offline?): $e');
    }
  }

  /// Request notification permissions
  Future<NotificationSettings> _requestPermissions() async {
    return _messaging!.requestPermission();
  }

  /// Initialize local notifications for foreground display
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(notificationIcon);
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
