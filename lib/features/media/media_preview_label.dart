// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';

import 'media_attachment.dart';

/// One line describing a media message wherever its bubble isn't drawn: reply
/// quotes, search hits, favorites, the local notification banner.
///
/// **Why this replaced the filename.** The old label was `📎 IMG_20260804.jpg`
/// — the attachment's own name. Two problems. It reads like a directory
/// listing rather than a message, and the filename is the one thing about a
/// media message we deliberately keep out of the object path (audit M9: the
/// name lives only inside the per-recipient-encrypted descriptor). Putting it
/// back into the most-glanced-at line in the app undid the point.
///
/// A caption always wins: the sender's own words beat any noun we could pick.
String mediaPreviewLabel(MediaAlbum album) {
  final caption = album.caption;
  final icon = _icon(album);
  if (caption != null && caption.isNotEmpty) return '$icon $caption';
  return '$icon ${_noun(album)}';
}

/// The single type an album consists of, or null when it mixes types.
MediaType? _uniformType(MediaAlbum album) {
  final first = album.first.mediaType;
  for (final item in album.items) {
    if (item.mediaType != first) return null;
  }
  return first;
}

String _icon(MediaAlbum album) {
  switch (_uniformType(album)) {
    case MediaType.image:
      return '\u{1F4F7}'; // 📷
    case MediaType.video:
      return '\u{1F3A5}'; // 🎥
    case MediaType.audio:
      return '\u{1F3B5}'; // 🎵
    case MediaType.file:
    case null:
      return '\u{1F4CE}'; // 📎 — plain file, or a mixed album
  }
}

String _noun(MediaAlbum album) {
  final count = album.items.length;
  final type = _uniformType(album);
  // A mixed album has no honest noun — "3 photos and a video" is more than a
  // preview line can carry, so it degrades to the neutral count.
  if (type == null) return 'media.preview.mixed'.tr(args: ['$count']);
  final key = switch (type) {
    MediaType.image => 'photo',
    MediaType.video => 'video',
    MediaType.audio => 'audio',
    MediaType.file => 'file',
  };
  // Albums always hold ≥2 items, so the singular/plural split needs no plural
  // machinery — and stays clear of easy_localization's .plural(), which throws
  // a LateInitializationError before a locale is loaded.
  return count == 1
      ? 'media.preview.$key'.tr()
      : 'media.preview.${key}s'.tr(args: ['$count']);
}
