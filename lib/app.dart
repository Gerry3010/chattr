// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'core/navigation/navigation_provider.dart';
import 'features/identity/identity_color.dart';
import 'features/profiles/profiles_controller.dart';
import 'core/notifications/active_chat_provider.dart';
import 'core/notifications/in_app_notification_overlay.dart';
import 'core/theme/theme_controller.dart';
import 'core/updates/android_update_listener.dart';
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
import 'features/push_notifications/push_render_cache_sync.dart';

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

    // The wording a push-woken background isolate renders with. Written here
    // and not only from the chat list: after an app update that adds template
    // keys, a push arriving before the user next opens a chat list would fall
    // back to the English defaults. Locale is resolved by now (EasyLocalization
    // wraps this widget), and putTemplates is a cheap idempotent write.
    unawaited(syncPushRenderTemplates());

    // chatview keeps its own global string table (date separators, reply
    // headers, typing, …) — align it with the app locale on every build.
    syncChatViewLocale(context.locale);

    // One identity colour per user everywhere (audit M2): the chatview fork
    // resolves its initials-circle background through this hook (p20), so
    // in-chat message circles, reaction pills, the reaction sheet and the chat
    // header all match UserAvatar/the chat list. Falls back to the fork's
    // name-hash when we know nothing about the user.
    chatview.ProfileImageWidget.fallbackColorResolver = (userId, userName) {
      final profiles = ref.read(profilesControllerProvider);
      var id = userId;
      String? key;
      if (id != null && id.isNotEmpty) {
        key = profiles[id]?.identityPublicKey;
      } else if (userName != null && userName.isNotEmpty) {
        // Some fork sites (app bar) only know the display name; Chattr
        // usernames are unique handles, so a name lookup is unambiguous.
        for (final p in profiles.values) {
          if (p.username == userName) {
            id = p.id;
            key = p.identityPublicKey;
            break;
          }
        }
      }
      if (id == null || id.isEmpty) return null;
      return IdentityColor.forKeyOrId(key, id);
    };
    // p21: and the letter's colour, so ONE contrast rule covers both the fork's
    // circles and the app-side ones. The fork used to pick white below luminance
    // 0.5 while the app used the WCAG crossover (~0.179) — same user, same
    // background, black letter in the chat list and white in the chat header.
    chatview.ProfileImageWidget.fallbackForegroundResolver =
        IdentityColor.foregroundOn;

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
          child: PipOverlayHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
      home: const AndroidUpdateListener(
        child: WebUpdateListener(
          child: NewChatToastListener(
            child: ShareTargetListener(
              child: LastActivePinger(child: AuthStateHandler()),
            ),
          ),
        ),
      ),
    );
  }
}
