// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Catalog of selectable in-app notification sounds.
///
/// Each option maps a stable [id] (persisted in secure storage) to a bundled
/// asset and an i18n [labelKey]. The [silent] option carries no asset — when
/// selected, no sound is played. Keep [id]s stable: they are what gets stored.
library;

class NotificationSoundOption {
  /// Stable key persisted in secure storage. Never change once shipped.
  final String id;

  /// AssetSource path (relative to the bundled `assets/` prefix), or null for
  /// the silent option.
  final String? asset;

  /// easy_localization key for the display label.
  final String labelKey;

  const NotificationSoundOption({
    required this.id,
    required this.asset,
    required this.labelKey,
  });

  bool get isSilent => asset == null;
}

/// Default selection used when nothing is stored yet.
const kDefaultNotificationSoundId = 'rise';

/// All selectable sounds, in display order. The first entries are the
/// synth/terminal-style tones, followed by the richer curated chimes, then the
/// silent option last.
const List<NotificationSoundOption> kNotificationSounds = [
  NotificationSoundOption(
      id: 'rise', asset: 'sounds/rise.mp3', labelKey: 'sounds.rise'),
  NotificationSoundOption(
      id: 'ping', asset: 'sounds/ping.mp3', labelKey: 'sounds.ping'),
  NotificationSoundOption(
      id: 'chime', asset: 'sounds/chime.mp3', labelKey: 'sounds.chime'),
  NotificationSoundOption(
      id: 'blip', asset: 'sounds/blip.mp3', labelKey: 'sounds.blip'),
  NotificationSoundOption(
      id: 'matrix', asset: 'sounds/matrix.mp3', labelKey: 'sounds.matrix'),
  NotificationSoundOption(
      id: 'bubble', asset: 'sounds/bubble.mp3', labelKey: 'sounds.bubble'),
  NotificationSoundOption(
      id: 'futuristic',
      asset: 'sounds/futuristic.mp3',
      labelKey: 'sounds.futuristic'),
  NotificationSoundOption(
      id: 'pleasant',
      asset: 'sounds/pleasant.mp3',
      labelKey: 'sounds.pleasant'),
  NotificationSoundOption(
      id: 'pleasant2',
      asset: 'sounds/pleasant2.mp3',
      labelKey: 'sounds.pleasant2'),
  NotificationSoundOption(
      id: 'pleasant3',
      asset: 'sounds/pleasant3.mp3',
      labelKey: 'sounds.pleasant3'),
  NotificationSoundOption(
      id: 'playful', asset: 'sounds/playful.mp3', labelKey: 'sounds.playful'),
  NotificationSoundOption(
      id: 'silent', asset: null, labelKey: 'sounds.silent'),
];

/// Resolves a stored id to its option, falling back to the default (and, if
/// that is somehow missing, the first entry).
NotificationSoundOption notificationSoundById(String id) {
  for (final s in kNotificationSounds) {
    if (s.id == id) return s;
  }
  for (final s in kNotificationSounds) {
    if (s.id == kDefaultNotificationSoundId) return s;
  }
  return kNotificationSounds.first;
}
