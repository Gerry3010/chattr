// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Slide-to-Timestamp (#107b) UI: the compact "peek" chip revealed while
// opposite-swiping a bubble, plus the per-recipient info sheet (groups). Read
// times are gated by the reciprocal read-receipt privacy setting (showRead):
// when the local user has read receipts off, no "read" info is shown anywhere.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/utils/app_time.dart';
import '../../../features/messages/message_model.dart';
import '../../../features/messages/messages_controller.dart';
import '../../../features/profiles/widgets/user_avatar.dart';

DateTime _latest(Iterable<DateTime> times) =>
    times.reduce((a, b) => a.isAfter(b) ? a : b);

/// Aggregate status a Slide-to-Timestamp peek reflects. `incoming` is a foreign
/// message (we only know when it was sent); the others are our own message's
/// state across all recipients.
enum TimestampStatus { incoming, sent, delivered, read }

/// The status + the single relevant time a peek chip should show, computed
/// purely from a [Message] (no BuildContext) so it is unit-testable. `showRead`
/// is the reciprocal read-receipt setting: when false, a message never reports
/// `read` — it caps at `delivered`.
class TimestampSummary {
  final TimestampStatus status;
  final DateTime time;
  const TimestampSummary(this.status, this.time);
}

TimestampSummary timestampSummary(
  Message m,
  String? currentUserId,
  bool showRead,
) {
  final isOwn = m.senderId == currentUserId;
  if (!isOwn) return TimestampSummary(TimestampStatus.incoming, m.createdAt);

  final allReceived =
      m.receivedAt.isNotEmpty && m.receivedAt.values.every((v) => v != null);
  final allRead =
      m.readAt.isNotEmpty && m.readAt.values.every((v) => v != null);
  if (showRead && allRead) {
    return TimestampSummary(
        TimestampStatus.read, _latest(m.readAt.values.whereType<DateTime>()));
  }
  if (allReceived) {
    return TimestampSummary(TimestampStatus.delivered,
        _latest(m.receivedAt.values.whereType<DateTime>()));
  }
  return TimestampSummary(TimestampStatus.sent, m.createdAt);
}

/// Compact chip revealed in the gutter while opposite-swiping a bubble.
/// Outgoing bubbles show a status tick + the relevant time; incoming bubbles
/// show only the sent time (WhatsApp-style peek).
Widget buildTimestampRevealChip({
  required BuildContext context,
  required Message message,
  required String? currentUserId,
  required bool showReadReceipts,
}) {
  final scheme = Theme.of(context).colorScheme;
  final locale = context.locale.toString();
  final summary =
      timestampSummary(message, currentUserId, showReadReceipts);

  IconData? icon;
  Color iconColor = scheme.onSurfaceVariant;
  switch (summary.status) {
    case TimestampStatus.incoming:
      icon = null; // no tick for foreign messages
      break;
    case TimestampStatus.sent:
      icon = Icons.done;
      break;
    case TimestampStatus.delivered:
      icon = Icons.done_all;
      break;
    case TimestampStatus.read:
      icon = Icons.done_all;
      iconColor = scheme.primary;
      break;
  }
  final time = AppTime.hm(summary.time, locale);

  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 3),
        ],
        Text(
          time,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

/// Per-recipient timestamp sheet (opened by a hard opposite-swipe in groups, or
/// the "Info" action). Lists each recipient with their delivered/read times.
/// For incoming/foreign messages only the current user's own row is available
/// (server RLS), so it shows the sent time + your own received/read.
Future<void> showTimestampInfoSheet({
  required BuildContext context,
  required String chatId,
  required Message message,
  required Map<String, String> usernames,
  required String? currentUserId,
  required bool showReadReceipts,
}) {
  final locale = context.locale.toString();
  final isOwn = message.senderId == currentUserId;

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      // The sheet is its own route, so a chat-screen rebuild never reaches it —
      // it must watch the message itself. Without this, a received/read receipt
      // arriving while the sheet is open would not update the rows (the caller
      // passes a snapshot taken at open time).
      return Consumer(
        builder: (context, ref, _) {
          final messages = ref.watch(messagesControllerProvider(chatId));
          final live = messages.whereType<Message>().firstWhere(
                (m) => m.id == message.id,
                orElse: () => message,
              );
          // Own → every recipient row; incoming → just our own row (RLS).
          final recipientIds = live.receivedAt.keys.toList();
          final scheme = Theme.of(sheetContext).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    'chat_view.message_info'.tr(),
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'chat_view.ts_sent'
                        .tr(args: [AppTime.ymdHm(live.createdAt, locale)]),
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (recipientIds.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'chat_view.ts_no_recipients'.tr(),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      for (final id in recipientIds)
                        _RecipientRow(
                          userId: id,
                          name: isOwn
                              ? (usernames[id] ?? _shortId(id))
                              : 'chat_detail.you'.tr(),
                          received: live.receivedAt[id],
                          read: showReadReceipts ? live.readAt[id] : null,
                          showReadColumn: showReadReceipts,
                          locale: locale,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

class _RecipientRow extends StatelessWidget {
  final String userId;
  final String name;
  final DateTime? received;
  final DateTime? read;
  final bool showReadColumn;
  final String locale;

  const _RecipientRow({
    required this.userId,
    required this.name,
    required this.received,
    required this.read,
    required this.showReadColumn,
    required this.locale,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dash = '—';
    return ListTile(
      // Shared reactive avatar (real profile photo, initials fallback).
      leading: UserAvatar(userId: userId, radius: 20),
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'chat_view.ts_delivered'.tr(args: [
              received != null ? AppTime.hm(received!, locale) : dash,
            ]),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          if (showReadColumn)
            Text(
              'chat_view.ts_read'.tr(args: [
                read != null ? AppTime.hm(read!, locale) : dash,
              ]),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
