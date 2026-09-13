// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';

import 'place_envelope.dart';

/// One line describing a shared marker or calendar entry wherever its card
/// isn't drawn: reply quotes, search hits, favorites, the notification banner.
///
/// The counterpart of `mediaPreviewLabel`, and it exists for the same reason:
/// an envelope is JSON, and every place that shows "the last message" as raw
/// text would otherwise print `{"_chattr_location":1,…}` at the user. Returns
/// null when [content] is not one of ours, so callers can chain it.
///
/// Names the place when it has one — a pin labelled "Café Central" is more use
/// in a quote line than the word "Standort" — and never the coordinates: they
/// say nothing at a glance and are the one part worth not scattering around.
String? placePreviewLabel(String? content) {
  final location = LocationEnvelope.tryParse(content);
  if (location != null) {
    final label = location.name ?? location.address;
    return label == null || label.isEmpty
        ? '\u{1F4CD} ${'places.location'.tr()}' // 📍
        : '\u{1F4CD} $label';
  }
  final event = EventEnvelope.tryParse(content);
  if (event != null) return '\u{1F4C5} ${event.title}'; // 📅
  return null;
}
