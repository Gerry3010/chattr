// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../features/messages/message_model.dart' show SystemMessageState;

/// The centred pill that renders a system message ("X ist beigetreten", …).
///
/// Every system message used to share one grey pill, so a routine join and a
/// key rotation you are supposed to verify out of band looked identical. The
/// chip now carries the message's [SystemMessageState] as a tint plus a
/// leading icon, so severity reads at a glance while scrolling.
class SystemMessageChip extends StatelessWidget {
  const SystemMessageChip({
    super.key,
    required this.text,
    required this.state,
  });

  final String text;
  final SystemMessageState state;

  @override
  Widget build(BuildContext context) {
    final style = _SystemChipStyle.of(context, state);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: BorderRadius.circular(12),
          border: style.border == null
              ? null
              : Border.all(color: style.border!, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              // Nudged down to sit on the first line's optical centre when the
              // text wraps to two lines.
              padding: const EdgeInsets.only(top: 1, right: 6),
              child: Icon(style.icon, size: 13, color: style.foreground),
            ),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: style.foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolved colours + icon for one [SystemMessageState].
class _SystemChipStyle {
  const _SystemChipStyle({
    required this.foreground,
    required this.background,
    required this.icon,
    this.border,
  });

  final Color foreground;
  final Color background;
  final Color? border;
  final IconData icon;

  factory _SystemChipStyle.of(BuildContext context, SystemMessageState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    switch (state) {
      // Routine bookkeeping stays deliberately quiet — same neutral pill as
      // before, just with an icon so all four states share one silhouette.
      case SystemMessageState.info:
        return _SystemChipStyle(
          foreground: scheme.onSurfaceVariant,
          background: scheme.surfaceContainerHighest,
          icon: Icons.info_outline,
        );
      case SystemMessageState.success:
        return _tinted(
          // Material 3 has no "success" role, so these are fixed hues picked
          // per brightness rather than derived from the scheme.
          isDark ? const Color(0xFF7FCB86) : const Color(0xFF2E7D32),
          scheme.surface,
          isDark,
          Icons.check_circle_outline,
        );
      case SystemMessageState.warning:
        return _tinted(
          isDark ? const Color(0xFFE3B457) : const Color(0xFF8A5A00),
          scheme.surface,
          isDark,
          Icons.warning_amber_rounded,
        );
      case SystemMessageState.error:
        return _tinted(
          isDark ? const Color(0xFFF0A9A2) : scheme.error,
          scheme.surface,
          isDark,
          Icons.error_outline,
        );
    }
  }

  /// A tinted-but-opaque chip: the accent is blended ONTO the surface rather
  /// than laid over it at low alpha, so the pill stays legible whatever the
  /// chat wallpaper behind it happens to be.
  static _SystemChipStyle _tinted(
    Color accent,
    Color surface,
    bool isDark,
    IconData icon,
  ) {
    return _SystemChipStyle(
      foreground: accent,
      background: Color.alphaBlend(
        accent.withValues(alpha: isDark ? 0.20 : 0.14),
        surface,
      ),
      border: accent.withValues(alpha: 0.35),
      icon: icon,
    );
  }
}
