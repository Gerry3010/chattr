// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notifications/notification_sound.dart';
import '../../core/notifications/notification_sound_controller.dart';
import '../../core/notifications/notification_sounds.dart';
import '../../core/notifications/sound_option_tile.dart';

/// Notification sound picker: choose among the bundled tones. Tapping a row
/// selects it *and* plays a preview; the leading play button re-previews the
/// currently focused sound without changing anything else.
class NotificationSoundScreen extends ConsumerWidget {
  const NotificationSoundScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(notificationSoundControllerProvider);
    final controller = ref.read(notificationSoundControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text('settings.notification_sound'.tr())),
      body: ListView(
        children: [
          for (final sound in kNotificationSounds)
            SoundOptionTile(
              title: sound.labelKey.tr(),
              selected: sound.id == selectedId,
              icon: sound.isSilent ? Icons.notifications_off : null,
              onPreview: sound.isSilent
                  ? null
                  : () => NotificationSound.instance
                      .play(sound.asset!, preview: true),
              onTap: () {
                controller.select(sound.id);
                // Preview on selection (except for the silent option).
                if (sound.asset != null) {
                  NotificationSound.instance.play(sound.asset!, preview: true);
                }
              },
            ),
        ],
      ),
    );
  }
}
