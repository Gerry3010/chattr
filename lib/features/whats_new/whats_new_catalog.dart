// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// One "new in this version" card: an icon, a headline, a short text. The
/// strings are translation keys, so a card speaks the app's language.
class WhatsNewEntry {
  const WhatsNewEntry({
    required this.icon,
    required this.headlineKey,
    required this.bodyKey,
  });

  final IconData icon;
  final String headlineKey;
  final String bodyKey;
}

/// The cards, keyed by the version that brought them.
///
/// Add an entry for a release that changes how people use the app — not for
/// every fix; that is what the changelog is for. A card is shown once, after
/// the update that carries it (see `unreadWhatsNew`), and comes back only if
/// the user resets it in the settings.
const Map<String, WhatsNewEntry> whatsNewCatalog = {
  '1.32.0': WhatsNewEntry(
    icon: Icons.call_outlined,
    headlineKey: 'whats_new.entries.calls.headline',
    bodyKey: 'whats_new.entries.calls.body',
  ),
  '1.32.2': WhatsNewEntry(
    icon: Icons.keyboard_arrow_down,
    headlineKey: 'whats_new.entries.call_minimize.headline',
    bodyKey: 'whats_new.entries.call_minimize.body',
  ),
  '1.33.0': WhatsNewEntry(
    icon: Icons.cloud_off_outlined,
    headlineKey: 'whats_new.entries.offline.headline',
    bodyKey: 'whats_new.entries.offline.body',
  ),
};
