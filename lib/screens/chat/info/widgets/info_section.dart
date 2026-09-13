// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// Section label of the chat info.
///
/// Deliberately the same language as the settings (`settings_screen.dart`):
/// flat, titled sections instead of a stack of equally weighted cards. When
/// everything is a card, nothing is more important than the rest — and that is
/// exactly how the old view read.
class SectionHeader extends StatelessWidget {
  final String text;

  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

/// Row with icon, title, optional state text on the right and a chevron.
///
/// [trailingText] carries the STATE, not just a number: "muted until Fri,
/// 18:00" belongs on the row itself. Before, the state of a setting sometimes
/// stood only inside the menu one sets it from — one had to open it to see
/// whether it was on.
class InfoActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final VoidCallback? onTap;
  final Color? color;

  /// Chevron on the right. Off for rows that ACT rather than lead onwards —
  /// "leave chat" leads nowhere, and a chevron beside it promises exactly that.
  final bool chevron;

  const InfoActionRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.onTap,
    this.color,
    this.chevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: color == null ? null : TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: (onTap == null || !chevron) && trailingText == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailingText != null)
                  Text(
                    trailingText!,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                if (onTap != null && chevron) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ],
            ),
      onTap: onTap,
    );
  }
}
