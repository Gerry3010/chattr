// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The two registers of notification sounds (1.26.2).
//
// Gerry on the iPhone: in silent mode the preview in the sound picker played
// nothing — a play button that stays silent looks broken. The incoming sound,
// by contrast, MUST stay silent in silent mode. Both hang on the same process-
// wide iOS session, and that is precisely why there is a test here: whoever one
// day unifies the session thereby switches off the silent switch for all
// incoming notices, unnoticed.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/notifications/notification_sound.dart';

void main() {
  test('the preview plays despite the silent switch', () {
    final ctx = NotificationSound.audioContextFor(preview: true);
    expect(ctx.iOS.category, AVAudioSessionCategory.playback,
        reason: 'playback is the only category that ignores the switch');
    expect(ctx.android.usageType, AndroidUsageType.media,
        reason: 'a muted notification channel must not silence the button'
            'lahmlegen');
  });

  test('the incoming sound obeys the silent switch', () {
    final ctx = NotificationSound.audioContextFor(preview: false);
    expect(ctx.iOS.category, isNot(AVAudioSessionCategory.playback),
        reason: 'otherwise every incoming message rings in the cinema');
    expect(ctx.iOS.category, AVAudioSessionCategory.ambient);
    expect(ctx.android.usageType, AndroidUsageType.notification);
  });

  test('neither of the two cases interrupts other music', () {
    // `playback` would stop other people's music without the option, so the
    // preview carries it. `ambient` mixes of its own accord — and audioplayers
    // THROWS if one sets it there anyway. That is exactly what stood there
    // before, ran into the swallowed error in a debug build and left the
    // session on the default category `playback`: the incoming sound would have
    // ignored the silent switch.
    expect(NotificationSound.audioContextFor(preview: true).iOS.options,
        contains(AVAudioSessionOptions.mixWithOthers));
    expect(NotificationSound.audioContextFor(preview: false).iOS.options,
        isEmpty);
    for (final preview in [true, false]) {
      expect(
          NotificationSound.audioContextFor(preview: preview)
              .android
              .audioFocus,
          AndroidAudioFocus.none,
          reason: 'preview=$preview');
    }
  });
}
