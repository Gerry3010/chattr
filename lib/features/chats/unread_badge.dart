// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../push_notifications/push_cache_bridge_ios.dart';
import 'chats_controller.dart';

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
/// **Both sinks get the same number, and that is the point.** The foreground
/// badge and the extension's base must never disagree — if they came from two
/// different counts, the badge would jump every time the app changed hands
/// between the two. One listener, one value, two writes.
///
/// Mobile-only, best-effort: web has no launcher badge, and some Android
/// launchers reject the call — either way a failure is swallowed.
final appBadgeSyncProvider = Provider<void>((ref) {
  ref.listen<int>(
    totalUnreadProvider,
    (prev, next) {
      if (prev == next) return;
      unawaited(_setBadge(next));
      // Re-seeds the extension's base. Deliberately fired on EVERY change, not
      // just on the way down: the extension can only add to what it last saw,
      // so a stale base drifts further with every push it renders.
      unawaited(mirrorUnreadTotalForAppGroup(next));
    },
    fireImmediately: true,
  );
});

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
