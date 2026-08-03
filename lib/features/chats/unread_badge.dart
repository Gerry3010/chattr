// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import 'chats_controller.dart';

/// Total unread messages across all chats — the single source of truth for the
/// app-icon badge. Defined to match EXACTLY what a push carries in `aps.badge`
/// (the server sums the same `last_read_at`-based per-chat unread, migration
/// 00053/00054), so the badge never jumps between a background push (server) and
/// the foreground read count (client).
final totalUnreadProvider = Provider<int>((ref) {
  final chats = ref.watch(chatsControllerProvider);
  return chats.fold<int>(0, (sum, c) => sum + c.unreadCount);
});

/// Keeps the OS app-icon badge in lock-step with [totalUnreadProvider]. Kept
/// alive from app startup (watched in `ChattrApp`) so it owns the badge for the
/// whole session — the badge is now fully client-derived on the foreground and
/// server-set (`aps.badge`) while backgrounded, both from the same total.
///
/// Mobile-only, best-effort: web has no launcher badge, and some Android
/// launchers reject the call — either way a failure is swallowed.
final appBadgeSyncProvider = Provider<void>((ref) {
  ref.listen<int>(
    totalUnreadProvider,
    (prev, next) {
      if (prev == next) return;
      unawaited(_setBadge(next));
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
