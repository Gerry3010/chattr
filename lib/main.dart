// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// hide TextDirection: easy_localization re-exports intl's TextDirection (LTR/RTL)
// which shadows Flutter's (dart:ui) one used by Directionality below.
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/core.dart';
import 'core/security/key_locked_exception.dart';

void main() async {
  // Debug only: UI automation (Marionette MCP) — has to run before any other
  // binding init; otherwise AppInit calls WidgetsFlutterBinding.
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  }

  // Hardening: a build that throws must NEVER render as a silent blank/grey box
  // (Flutter's default release ErrorWidget). Surface something visible instead —
  // a reentrant provider error once hid behind exactly that grey box, on a
  // notification cold start, for a very long time.
  ErrorWidget.builder = _buildErrorWidget;

  await _bootstrap();
}

/// A visible replacement for Flutter's default (blank-in-release) [ErrorWidget].
/// Self-contained (no Material/Directionality ancestor is guaranteed where a
/// build error is inserted).
Widget _buildErrorWidget(FlutterErrorDetails details) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      color: const Color(0xFF0A0A0A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFF00FF41), size: 40),
          const SizedBox(height: 12),
          const Text(
            'Etwas ist schiefgelaufen',
            style: TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            Text(
              '${details.exception}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    ),
  );
}

/// Boots the app. A startup crash must NOT leave the user on a blank white
/// screen with no way out (this is how an installed PWA could get stuck, unable
/// to even log out) — on failure we show a minimal retry screen that re-runs
/// this same bootstrap.
Future<void> _bootstrap() async {
  try {
    // Alle Services initialisieren
    await AppInit.initialize();
  } catch (e, st) {
    logger.error(
      'AppInit.initialize() failed at startup',
      error: e,
      stackTrace: st,
    );
    // A specifically UNREADABLE secure key store (audit #149) is not a generic
    // crash: the keys aren't gone, they can't be read. A blank "retry" would
    // loop forever. Show recovery guidance instead (retry is still offered in
    // case the keystore was only transiently locked, e.g. right after boot).
    if (e is SecureStorageUnreadableException) {
      runApp(_StorageUnreadableApp(onRetry: _bootstrap));
    } else {
      runApp(_StartupErrorApp(error: e, onRetry: _bootstrap));
    }
    return;
  }

  // media_kit (Inline-Video-Player) initialisieren
  MediaKit.ensureInitialized();

  // EasyLocalization initialisieren
  await EasyLocalization.ensureInitialized();

  // App mit Riverpod & EasyLocalization starten
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('de', 'DE'), Locale('en', 'US')],
      path: 'assets/translations',
      fallbackLocale: const Locale('de', 'DE'),
      child: const ProviderScope(
        child: ChattrApp(),
      ),
    ),
  );
}

/// Minimal, dependency-free fallback shown when startup init throws, so the
/// user sees an actionable screen instead of a white void. Intentionally does
/// not depend on Supabase/DB/localization being up.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFF00FF41), size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Chattr konnte nicht gestartet werden',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: onRetry,
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the local secure key store is UNREADABLE (audit #149) — a keystore
/// error, not a missing key. The keys are not gone but can't be read, so instead
/// of an endless blank retry we explain the recovery path. Dependency-free (no
/// Supabase/DB/localization), like [_StartupErrorApp]; a retry is still offered
/// in case the store was only transiently locked (e.g. immediately after boot).
class _StorageUnreadableApp extends StatelessWidget {
  const _StorageUnreadableApp({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_reset,
                    color: Color(0xFF00FF41), size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Schlüsselspeicher unlesbar',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Der lokale Schlüsselspeicher dieses Geräts kann gerade nicht '
                  'gelesen werden (z. B. nach einer System-/Sicherheits-Änderung). '
                  'Deine Nachrichten bleiben verschlüsselt und lassen sich ohne '
                  'den Schlüssel nicht öffnen.\n\n'
                  'Stelle dein Konto über deine 24-Wort-Wiederherstellungsphrase '
                  'wieder her — Identität und Chats kommen darüber zurück. Bei '
                  'einer Neuinstallation gehen nur lokal zwischengespeicherte '
                  'Nachrichten verloren.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: onRetry,
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
