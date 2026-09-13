// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/notifications/notification_sound.dart';
import '../../../core/notifications/notification_sound_controller.dart';
import '../../../core/notifications/notification_sounds.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chat_sound_controller.dart';
import '../../../features/chats/mute_controller.dart';
import '../components/mute_sheet.dart';
import '../../../core/notifications/sound_option_tile.dart';
import 'widgets/info_section.dart';

/// The notifications of ONE chat.
///
/// **Why this screen exists** (Gerry, 2026-08-25): before, two routes led to
/// exactly one action — the button below the picture and the "notifications"
/// row called the same code and both could only mute. Two entry points for one
/// thing are not convenience but a duplication that suggests to the user there
/// is something different behind each.
///
/// The button up top stays as a **shortcut**: it leads here and opens the
/// duration picker straight away — whoever is in a hurry loses nothing but ends
/// up in the right place instead of a dead end.
class ChatNotificationsScreen extends ConsumerStatefulWidget {
  final Chat chat;

  /// Opens the mute picker directly once the screen is up — the route via the
  /// quick button.
  final bool openMuteSheet;

  const ChatNotificationsScreen({
    super.key,
    required this.chat,
    this.openMuteSheet = false,
  });

  @override
  ConsumerState<ChatNotificationsScreen> createState() =>
      _ChatNotificationsScreenState();
}

class _ChatNotificationsScreenState
    extends ConsumerState<ChatNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // The quick button: here first, then straight to the duration picker. One
    // frame later, otherwise the sheet lies over a screen that does not exist
    // yet.
    if (widget.openMuteSheet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final controller = ref.read(mutedChatsProvider.notifier);
        if (!controller.isMuted(chat.id)) {
          showMuteSheet(context: context, ref: ref, chatId: chat.id);
        }
      });
    }
  }

  Chat get chat => widget.chat;

  @override
  Widget build(BuildContext context) {
    final muted = ref.watch(chatIsMutedProvider(chat.id));
    final until = ref.read(mutedChatsProvider.notifier).mutedUntil(chat.id);
    final eigenerTon =
        ref.watch(chatSoundControllerProvider)[chat.id];

    // The subtitle describes the MUTE state, not the notification state: under
    // the title "mute" the old "on" (from the notifications-on vocabulary) read
    // as "muted: on". Now "off" says that muting is off.
    final state = !muted
        ? 'chat_notifications.mute_off'.tr()
        : (until == null
            ? 'chat_detail.muted_forever'.tr()
            : 'chat_detail.muted_until'
                .tr(args: [formatMuteUntil(context, until)]));

    return Scaffold(
      appBar: AppBar(title: Text('chat_detail.notifications'.tr())),
      body: ListView(
        children: [
          InfoActionRow(
            icon: muted ? Icons.notifications_off : Icons.notifications_active,
            title: 'chat_notifications.mute'.tr(),
            subtitle: state,
            onTap: () => _setMuted(context, ref),
          ),
          const Divider(height: 1),
          SectionHeader('chat_notifications.sound_section'.tr()),
          // Label honestly rather than sound generous: the sound applies to the
          // in-app banner while the app is open. The system notification hangs
          // on a channel on Android, and channels cannot be changed after they
          // are created — there one would need a channel per sound. Promising
          // it here without keeping it makes the setting worthless.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'chat_notifications.sound_scope'.tr(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          // Same construction as the general sound picker in the settings
          // (ListTile + check, no radio) — two selection lists for the same
          // thing should not look different.
          SoundOptionTile(
            title: 'chat_notifications.sound_default'.tr(),
            subtitle: notificationSoundById(
              ref.watch(notificationSoundControllerProvider),
            ).labelKey.tr(),
            selected: eigenerTon == null,
            icon: Icons.settings_outlined,
            onTap: () => _tonWaehlen(ref, null),
          ),
          for (final ton in kNotificationSounds)
            SoundOptionTile(
              title: ton.labelKey.tr(),
              selected: eigenerTon == ton.id,
              icon: ton.isSilent ? Icons.notifications_off : null,
              onPreview: ton.isSilent
                  ? null
                  : () => NotificationSound.instance
                      .play(ton.asset!, preview: true),
              onTap: () => _tonWaehlen(ref, ton.id),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _setMuted(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(mutedChatsProvider.notifier);
    if (controller.isMuted(chat.id)) {
      await controller.unmute(chat.id);
    } else if (context.mounted) {
      await showMuteSheet(context: context, ref: ref, chatId: chat.id);
    }
  }

  void _tonWaehlen(WidgetRef ref, String? id) {
    // Play it briefly when choosing — otherwise one is choosing a name, not a
    // sound.
    final gewaehlt = notificationSoundById(
      id ?? ref.read(notificationSoundControllerProvider),
    );
    if (!gewaehlt.isSilent) NotificationSound.instance.play(gewaehlt.asset!, preview: true);
    ref.read(chatSoundControllerProvider.notifier).select(chat.id, id);
  }
}
