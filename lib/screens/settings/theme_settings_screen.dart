// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';

/// Theme picker submenu: choose among the available themes, each with a swatch
/// and (where present) a small wallpaper preview.
class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(themeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text('settings.appearance'.tr())),
      body: ListView(
        children: [
          for (final theme in AppTheme.values)
            ListTile(
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: theme.swatch,
                child: Icon(theme.icon, size: 18, color: Colors.white),
              ),
              title: Text(theme.label.tr()),
              subtitle: theme.wallpaper != null
                  ? Text('settings.has_wallpaper'.tr())
                  : null,
              trailing: theme.wallpaper != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 44,
                        height: 32,
                        child: ColoredBox(
                          // Match the preview backdrop to the theme's actual
                          // brightness — with the dark scheme hardcoded, light
                          // themes rendered as near-black tiles.
                          color: (theme.config.mode == ThemeMode.dark
                                  ? theme.config.dark
                                  : theme.config.light)
                              .colorScheme
                              .surfaceContainerLowest,
                          child: theme.wallpaper!.endsWith('.svg')
                              ? SvgPicture.asset(
                                  theme.wallpaper!,
                                  fit: BoxFit.cover,
                                )
                              : Image.asset(
                                  theme.wallpaper!,
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                    )
                  : (theme == selected
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary)
                      : null),
              selected: theme == selected,
              selectedTileColor:
                  Theme.of(context).colorScheme.primaryContainer.withValues(
                        alpha: 0.25,
                      ),
              onTap: () =>
                  ref.read(themeControllerProvider.notifier).setTheme(theme),
            ),
        ],
      ),
    );
  }
}
