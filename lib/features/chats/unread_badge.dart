// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import '../push_notifications/push_cache_bridge_ios.dart';
import 'chats_controller.dart';
import 'chats_load_status.dart';

/// Total unread messages across all chats — the single source of truth for the
/// app-icon badge.
///
/// The per-chat counts are computed on the device from the local message store
/// (`ChatsController._withLocalUnread`); the server's `unread_count` is
/// discarded.
///
/// While the app is BACKGROUNDED on iOS the badge still comes from the push's
/// `aps.badge`, which the Edge Function derives from `chat_members.last_read_at`
/// (migrations 00053/00054) — the last server-side record of when the user
/// opened which chat. It is on its way out: this provider now also publishes the
/// exact total into the App Group ([mirrorUnreadTotalForAppGroup]), from which
/// the Notification Service Extension sets the badge itself. Once that ships and
/// the fleet has it, `aps.badge`, `mark_chat_read`, the RPC and the column go
/// together — in that order, because dropping the server side first would freeze
/// the badge on every iPhone without the new extension.
///
/// Android and web never used `aps.badge`.
final totalUnreadProvider = Provider<int>((ref) {
  final chats = ref.watch(chatsControllerProvider);
  return chats.fold<int>(0, (sum, c) => sum + c.unreadCount);
});

/// Keeps the OS app-icon badge in lock-step with [totalUnreadProvider], and
/// publishes the same number into the iOS App Group so the Notification
/// Service Extension can carry it on while the app is backgrounded.
///
/// Kept alive from app startup (watched in `ChattrApp`) so it owns the badge
/// for the whole session.
///
/// **Both sinks get the same number, and that is the point** — see [_publish].
///
/// Two occasions write it: whenever the local total CHANGES, and whenever the
/// app returns to the foreground. The second one is not redundant. The
/// extension raises the badge by itself and can only ever add; if the local
/// total never mirrored that raise, a change-only listener has no occasion to
/// take it back, and the number stays up for good.
///
/// Mobile-only, best-effort: web has no launcher badge, and some Android
/// launchers reject the call — either way a failure is swallowed.
final appBadgeSyncProvider = Provider<void>((ref) {
  // Only a list that has been read says anything about unread messages. While
  // locked (or not loaded yet) the list is empty, and publishing its 0 wiped
  // the icon badge and re-seeded the extension's base with it.
  bool loaded() => ref.read(chatsLoadStatusProvider) == ChatsLoadStatus.ready;

  // The list and its status settle in the same turn, so both listeners below
  // can report the same number; it goes out once.
  int? published;
  void publishChange(int total) {
    if (!loaded() || total == published) return;
    published = total;
    unawaited(_publish(total));
  }

  ref.listen<int>(
    totalUnreadProvider,
    (prev, next) => publishChange(next),
    fireImmediately: true,
  );
  ref.listen<ChatsLoadStatus>(
    chatsLoadStatusProvider,
    (prev, next) => publishChange(ref.read(totalUnreadProvider)),
  );

  // Re-assert on every return to the foreground, even when the number did not
  // move. Without this the badge had no way back down: the extension raises it
  // on its own (it can only add), and the listener above fires on CHANGE — so
  // a raise that the local count never mirrored could never be taken back.
  // A push that creates no unread message is exactly that case, and Gerry's
  // iPhone sat at 8 with everything read.
  //
  // What is re-asserted is the REAL current total, never 0. Forcing a 0 here
  // was tried before and flashed a wrong count whenever unread chats remained
  // (see `FCMService.clearDeliveredNotifications`).
  final abo = ref
      .read(appLifecycleServiceProvider)
      .onResume
      .listen((_) {
    if (!loaded()) return;
    published = ref.read(totalUnreadProvider);
    unawaited(_publish(published!));
  });
  ref.onDispose(abo.cancel);
});

/// Writes [total] to BOTH sinks — unconditionally.
///
/// The OS badge and the extension's base must never disagree: if they came
/// from two different counts, the number would jump every time the badge
/// changed hands between foreground and background. One value, two writes.
/// Both start in the SAME turn — one must not wait for the other. The OS badge
/// goes through a platform channel, and hanging the App Group write behind it
/// would delay the extension's base by exactly as long as that call takes.
Future<void> _publish(int total) => Future.wait([
      _setBadge(total),
      // Re-seeds the extension's base. Deliberately also on the way UP: the
      // extension can only add to what it last saw, so a stale base drifts
      // further with every push it renders.
      mirrorUnreadTotalForAppGroup(total),
    ]);

Future<void> _setBadge(int count) async {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  try {
    await AppBadgePlus.updateBadge(count);
  } catch (e) {
    logger.warning('app badge update failed: $e', tag: 'UnreadBadge');
  }
}
