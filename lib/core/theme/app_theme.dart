// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A selectable app theme. Beyond the basic System/Light/Dark, there are a few
/// named looks (including a terminal/"Matrix" hacker theme and a golden-hour
/// "Forest" theme). The dark customs (Ocean/Sunset/Rose) each have a light
/// sibling (Beach/Sunrise/Sakura); Meadow and Paper are light-only. Matrix and
/// Forest are fully hand-crafted, committed dark looks (own ThemeData + font).
enum AppTheme {
  system,
  light,
  dark,
  matrix,
  forest,
  ocean,
  sunset,
  royal,
  rose,
  beach,
  sunrise,
  sakura,
  meadow,
  paper;

  String get label => switch (this) {
        AppTheme.system => 'settings.theme_system',
        AppTheme.light => 'settings.theme_light',
        AppTheme.dark => 'settings.theme_dark',
        AppTheme.matrix => 'settings.theme_matrix',
        AppTheme.forest => 'settings.theme_forest',
        AppTheme.ocean => 'settings.theme_ocean',
        AppTheme.sunset => 'settings.theme_sunset',
        AppTheme.royal => 'settings.theme_royal',
        AppTheme.rose => 'settings.theme_rose',
        AppTheme.beach => 'settings.theme_beach',
        AppTheme.sunrise => 'settings.theme_sunrise',
        AppTheme.sakura => 'settings.theme_sakura',
        AppTheme.meadow => 'settings.theme_meadow',
        AppTheme.paper => 'settings.theme_paper',
      };

  IconData get icon => switch (this) {
        AppTheme.system => Icons.brightness_auto,
        AppTheme.light => Icons.light_mode,
        AppTheme.dark => Icons.dark_mode,
        AppTheme.matrix => Icons.terminal,
        AppTheme.forest => Icons.forest,
        AppTheme.ocean => Icons.water,
        AppTheme.sunset => Icons.wb_twilight,
        AppTheme.royal => Icons.diamond,
        AppTheme.rose => Icons.local_florist,
        AppTheme.beach => Icons.beach_access,
        AppTheme.sunrise => Icons.wb_sunny,
        AppTheme.sakura => Icons.filter_vintage,
        AppTheme.meadow => Icons.grass,
        AppTheme.paper => Icons.sticky_note_2_outlined,
      };

  /// A small swatch shown in the settings list.
  Color get swatch => switch (this) {
        AppTheme.system => Colors.blueGrey,
        AppTheme.light => Colors.blue,
        AppTheme.dark => Colors.indigo,
        AppTheme.matrix => const Color(0xFF00FF41),
        AppTheme.forest => const Color(0xFF3B7A4E),
        AppTheme.ocean => Colors.teal,
        AppTheme.sunset => Colors.deepOrange,
        AppTheme.royal => const Color(0xFF7C4DFF),
        AppTheme.rose => const Color(0xFFFF4081),
        AppTheme.beach => const Color(0xFF00B8D4),
        AppTheme.sunrise => const Color(0xFFFF7043),
        AppTheme.sakura => const Color(0xFFF06292),
        AppTheme.meadow => const Color(0xFF66BB6A),
        AppTheme.paper => const Color(0xFF90A4AE),
      };

  /// Wallpaper asset for this theme (chat background), or null.
  /// AI-generated photographic WebP wallpapers (1:1, cropped via
  /// BoxFit.cover on any screen — keep important motifs centered when
  /// replacing them). Sunrise stays on hand-made SVG line art by choice.
  String? get wallpaper => switch (this) {
        AppTheme.matrix => 'assets/wallpapers/matrix.webp',
        AppTheme.forest => 'assets/wallpapers/forest.webp',
        AppTheme.ocean => 'assets/wallpapers/ocean.webp',
        AppTheme.sunset => 'assets/wallpapers/sunset.webp',
        AppTheme.royal => 'assets/wallpapers/royal.webp',
        AppTheme.rose => 'assets/wallpapers/rose.webp',
        AppTheme.beach => 'assets/wallpapers/beach.webp',
        // Sunrise stays on the hand-made SVG — Gerry liked it better than
        // the generated photo.
        AppTheme.sunrise => 'assets/wallpapers/sunrise.svg',
        AppTheme.sakura => 'assets/wallpapers/sakura.webp',
        AppTheme.meadow => 'assets/wallpapers/meadow.webp',
        AppTheme.paper => 'assets/wallpapers/paper.webp',
        _ => null,
      };

  ThemeConfig get config => switch (this) {
        AppTheme.system => _seeded(Colors.blue, ThemeMode.system),
        AppTheme.light => _seeded(Colors.blue, ThemeMode.light),
        AppTheme.dark => _seeded(Colors.blue, ThemeMode.dark),
        AppTheme.matrix => ThemeConfig(
            light: _matrixTheme,
            dark: _matrixTheme,
            mode: ThemeMode.dark,
          ),
        AppTheme.forest => ThemeConfig(
            light: _forestTheme,
            dark: _forestTheme,
            mode: ThemeMode.dark,
          ),
        AppTheme.ocean => _seeded(Colors.teal, ThemeMode.dark),
        AppTheme.sunset => _seeded(Colors.deepOrange, ThemeMode.dark),
        AppTheme.royal => _seeded(const Color(0xFF7C4DFF), ThemeMode.dark),
        AppTheme.rose => _seeded(const Color(0xFFFF4081), ThemeMode.dark),
        AppTheme.beach => _seeded(const Color(0xFF00B8D4), ThemeMode.light),
        AppTheme.sunrise => _seeded(const Color(0xFFFF7043), ThemeMode.light),
        AppTheme.sakura => _seeded(const Color(0xFFF06292), ThemeMode.light),
        AppTheme.meadow => _seeded(const Color(0xFF66BB6A), ThemeMode.light),
        AppTheme.paper => _seeded(const Color(0xFF607D8B), ThemeMode.light),
      };
}

class ThemeConfig {
  final ThemeData light;
  final ThemeData dark;
  final ThemeMode mode;
  const ThemeConfig({
    required this.light,
    required this.dark,
    required this.mode,
  });
}

ThemeConfig _seeded(Color seed, ThemeMode mode) => ThemeConfig(
      light: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
        useMaterial3: true,
      ),
      dark: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      mode: mode,
    );

/// Terminal/"Matrix" look — matches the sibling passbubble "phosphor terminal"
/// palette: phosphor-green accents on near-black, light body text, monospace.
final ThemeData _matrixTheme = () {
  const bg = Color(0xFF0A0A0A);
  const surface = Color(0xFF0E140F);
  const surfaceVariant = Color(0xFF121A14);
  const green = Color(0xFF00FF41);
  const greenFaint = Color(0xFF122B18);
  const onBg = Color(0xFFE0E0E0);
  const border = Color(0xFF1D3A24);
  final scheme = const ColorScheme.dark(
    primary: green,
    onPrimary: Colors.black,
    primaryContainer: greenFaint,
    onPrimaryContainer: green,
    secondary: green,
    onSecondary: Colors.black,
    surface: surface,
    onSurface: onBg,
    onSurfaceVariant: Color(0xFF5F8C6A),
    surfaceContainerLowest: bg,
    surfaceContainerLow: Color(0xFF0C110D),
    surfaceContainer: surface,
    surfaceContainerHigh: surfaceVariant,
    surfaceContainerHighest: Color(0xFF16221A),
    outline: border,
    error: Color(0xFFFF5F56),
  );
  final base = ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(backgroundColor: surface),
  );
  // JetBrains Mono — passbubble's brand font for the terminal look.
  return base.copyWith(
    textTheme: GoogleFonts.jetBrainsMonoTextTheme(base.textTheme),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: GoogleFonts.jetBrainsMono(
        color: onBg,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}();

/// "Forest" — a golden-hour pine-forest look drawn straight from the wallpaper
/// photo, kept at natural exposure (the theme is tuned to the image, not the
/// image to the theme). Own messages glow in the photo's warm beige sunlight
/// (primaryContainer), the other person's sit in deep tree-green
/// (surfaceContainerHigh); the accent is a light golden-orange. Body text is
/// warm cloud-mist Nunito (rounded, organic, easy to read); the app-bar title
/// uses a Fraunces soft-serif. A committed dark theme (same ThemeData for
/// light+dark, like Matrix).
final ThemeData _forestTheme = () {
  const bg = Color(0xFF0B120C); // deep pine shadow (scaffold / chrome)
  const surface = Color(0xFF121A12); // dark moss (app bar / composer)
  const beige = Color(0xFFEAC58E); // golden-hour beige sunlight — OWN bubble
  const accent = Color(0xFFE8B06A); // light golden-orange accent (buttons/links)
  const treeGreen = Color(0xFF2B4A33); // deep tree-green — OTHER bubble
  const foliage = Color(0xFF9DBB67); // fresh larch/spruce green (secondary)
  const bark = Color(0xFFD98F52); // warm sunlit bark (tertiary)
  const mist = Color(0xFFECE6D5); // warm cloud-mist (body / other-bubble text)
  const sage = Color(0xFFA7B197); // muted sage (secondary labels)
  const border = Color(0xFF3A4A33); // moss outline
  final scheme = const ColorScheme.dark(
    primary: accent,
    onPrimary: Color(0xFF2A1B08),
    primaryContainer: beige, // OWN bubble — golden-hour beige
    onPrimaryContainer: Color(0xFF3B2A12), // dark bark text on beige
    secondary: foliage,
    onSecondary: Color(0xFF1B2410),
    secondaryContainer: Color(0xFF2C3A1C),
    onSecondaryContainer: Color(0xFFCFE0A6),
    tertiary: bark,
    onTertiary: Color(0xFF2A1809),
    tertiaryContainer: Color(0xFF3E2A16),
    onTertiaryContainer: Color(0xFFF5CFAA),
    surface: surface,
    onSurface: mist,
    onSurfaceVariant: sage,
    surfaceContainerLowest: bg,
    surfaceContainerLow: Color(0xFF0F160F),
    surfaceContainer: surface,
    surfaceContainerHigh: treeGreen, // OTHER bubble — deep tree-green
    surfaceContainerHighest: Color(0xFF33553B),
    outline: border,
    outlineVariant: Color(0xFF26311F),
    inversePrimary: Color(0xFF6B5418),
    error: Color(0xFFFF6B5E),
    onError: Color(0xFF2A0906),
  );
  final base = ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(backgroundColor: surface),
  );
  return base.copyWith(
    textTheme: GoogleFonts.nunitoTextTheme(base.textTheme),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: GoogleFonts.fraunces(
        color: mist,
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}();

