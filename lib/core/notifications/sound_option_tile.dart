// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// One row of the sound picker — with a play button or with a stand-in icon,
/// but always the same width.
///
/// **Why this is a widget of its own** (Gerry, 2026-08-26): before, each of the
/// two sound screens built its row itself and set as `leading` either an
/// `IconButton` (48 wide, because a tap target has to be that big) or a bare
/// `Icon` (24 wide). `ListTile` measures the `leading` and starts the title
/// behind it — the rows without a button therefore slid a good twenty points to
/// the left, icon and text together. Affected were "as in the settings" and
/// "muted", so precisely the two rows meant to stand out of line without
/// falling out of the column.
///
/// The fix is not "remember next time" but the fixed footprint below: both
/// cases get the same box, and the icon is centred inside it. And because the
/// same fault stood in two places, the row now stands in one.
class SoundOptionTile extends StatelessWidget {
  /// The footprint of the `leading` — the minimum size of a tap target, so
  /// exactly what the `IconButton` occupies of its own accord. The icon without
  /// a button adapts to that, not the other way round.
  static const double leadingExtent = kMinInteractiveDimension;

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// Set means: this row has a sound one can listen to.
  final VoidCallback? onPreview;

  /// Stands in place of the play button when there is nothing to listen to.
  final IconData? icon;

  const SoundOptionTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.onPreview,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      leading: SizedBox(
        width: leadingExtent,
        height: leadingExtent,
        child: onPreview != null
            ? IconButton(
                icon: Icon(Icons.play_circle_outline, color: colors.primary),
                tooltip: 'sounds.preview'.tr(),
                onPressed: onPreview,
              )
            : Center(
                // `outline` is a border colour and barely legible on a dark
                // (and, when selected, additionally tinted) ground — the "as in
                // the settings" cog almost disappeared. Legible
                // `onSurfaceVariant`, and on selection the accent colour like
                // the check and the title.
                child: Icon(
                  icon ?? Icons.music_note,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
      ),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected ? Icon(Icons.check, color: colors.primary) : null,
      selected: selected,
      selectedTileColor: colors.primaryContainer.withValues(alpha: 0.25),
      onTap: onTap,
    );
  }
}
