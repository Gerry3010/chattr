// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'core/navigation/navigation_provider.dart';
import 'core/notifications/active_chat_provider.dart';
import 'core/notifications/in_app_notification_overlay.dart';
import 'core/theme/theme_controller.dart';
import 'core/updates/web_update_listener.dart';
import 'features/app_lock/app_lock_gate.dart';
import 'features/auth/widgets/auth_state_handler.dart';
import 'features/chat_view/chat_view_localization.dart';
import 'features/chats/new_chat_toast_listener.dart';
import 'features/chats/unread_badge.dart';
import 'features/media/widgets/pip_overlay.dart';
import 'features/presence/last_active_service.dart';
import 'features/screen_security/screen_security_controller.dart';
import 'features/share_target/share_target_listener.dart';

class ChattrApp extends ConsumerWidget {
  const ChattrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigationService = ref.watch(navigationServiceProvider);
    final themeConfig = ref.watch(themeControllerProvider).config;
    // Keep the screen-security controller alive from startup so FLAG_SECURE is
    // (re)applied on launch when the user enabled it.
    ref.watch(screenSecurityProvider);
    // Own the app-icon badge for the whole session — keeps it in sync with the
    // total unread count (matches the push `aps.badge`).
    ref.watch(appBadgeSyncProvider);

    // chatview keeps its own global string table (date separators, reply
    // headers, typing, …) — align it with the app locale on every build.
    syncChatViewLocale(context.locale);

    return MaterialApp(
      navigatorKey: navigationService.navigatorKey,
      navigatorObservers: [chatViewRouteObserver],
      title: 'Chattr',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: themeConfig.light,
      darkTheme: themeConfig.dark,
      themeMode: themeConfig.mode,
      // The lock gate sits in builder so it covers EVERY route (blur on
      // background, lock screen above navigation and dialogs). The in-app
      // notification overlay sits just inside it — above the Navigator, so its
      // banners (+ their sound/haptic alert) show on EVERY screen, not only the
      // home route; the lock gate stays outermost so banners never leak over a
      // locked screen. The PiP host sits innermost (under banners, under the
      // lock gate) so a minimized video floats above every route yet stays
      // hidden behind a locked screen.
      builder: (context, child) => AppLockGate(
        child: InAppNotificationOverlay(
          child: PipOverlayHost(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      home: const WebUpdateListener(
        child: NewChatToastListener(
          child: ShareTargetListener(
            child: LastActivePinger(
              child: AuthStateHandler(),
            ),
          ),
        ),
      ),
    );
  }
}
