// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../features/chats/mute_controller.dart';

/// Bottom sheet with mute-duration choices for one chat: quick presets,
/// a custom "until date & time" picker, or forever.
Future<void> showMuteSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String chatId,
}) async {
  final choice = await showModalBottomSheet<_MuteChoice>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'chat_detail.mute_until_title'.tr(),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.snooze),
            title: Text('chat_detail.mute_1h'.tr()),
            onTap: () => Navigator.pop(
                sheetContext, _MuteChoice(const Duration(hours: 1))),
          ),
          ListTile(
            leading: const Icon(Icons.nightlight_outlined),
            title: Text('chat_detail.mute_8h'.tr()),
            onTap: () => Navigator.pop(
                sheetContext, _MuteChoice(const Duration(hours: 8))),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_view_week),
            title: Text('chat_detail.mute_1w'.tr()),
            onTap: () => Navigator.pop(
                sheetContext, _MuteChoice(const Duration(days: 7))),
          ),
          ListTile(
            leading: const Icon(Icons.event),
            title: Text('chat_detail.mute_pick_date'.tr()),
            onTap: () =>
                Navigator.pop(sheetContext, const _MuteChoice.pickDate()),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_off),
            title: Text('chat_detail.mute_forever'.tr()),
            onTap: () =>
                Navigator.pop(sheetContext, const _MuteChoice.forever()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  DateTime? until;
  if (choice.pickDate) {
    until = await _pickDateTime(context);
    if (until == null) return; // picker cancelled — don't mute
  } else if (choice.duration != null) {
    until = DateTime.now().add(choice.duration!);
  }

  await ref.read(mutedChatsProvider.notifier).mute(chatId, until: until);

  if (!context.mounted) return;
  final label = until == null
      ? 'chat_detail.muted_forever'.tr()
      : 'chat_detail.muted_until'.tr(args: [formatMuteUntil(context, until)]);
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(label)));
}

/// "10.07.2026 um 18:30" — locale-aware date + time label for a mute expiry.
String formatMuteUntil(BuildContext context, DateTime until) {
  final locale = context.locale.toString();
  final local = until.toLocal();
  final date = DateFormat.yMd(locale).format(local);
  final time = DateFormat.Hm(locale).format(local);
  return 'chat_detail.mute_date_time'.tr(args: [date, time]);
}

Future<DateTime?> _pickDateTime(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365 * 5)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now),
  );
  if (time == null) return null;
  final until =
      DateTime(date.year, date.month, date.day, time.hour, time.minute);
  // A time earlier today would be in the past — treat as "right now + 1min"
  // rather than silently writing an already-expired mute.
  if (!until.isAfter(now)) return now.add(const Duration(minutes: 1));
  return until;
}

class _MuteChoice {
  final Duration? duration;
  final bool pickDate;

  const _MuteChoice(this.duration) : pickDate = false;
  const _MuteChoice.pickDate()
      : duration = null,
        pickDate = true;
  const _MuteChoice.forever()
      : duration = null,
        pickDate = false;
}
