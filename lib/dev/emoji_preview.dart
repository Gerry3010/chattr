// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// A separate entry point that shows ONLY the emoji picker:
//
// flutter run -t lib/dev/emoji_preview.dart -d <device>
//
// The picker otherwise hangs on a long-pressed message, and that presupposes an
// account, a chat and a second participant — so half a setup on the emulator
// before one sees the first pixel. Here a button is enough. The secure storage
// is the real one — otherwise one could not check precisely what one wants to
// check: whether the chosen skin tone survives a restart.
//
// Not part of the app: nothing imports this file, it lands in no build.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../screens/chat/components/reaction_emoji_picker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('de', 'DE'), Locale('en', 'US')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en', 'US'),
      startLocale: const Locale('de', 'DE'),
      child: const ProviderScope(child: _App()),
    ),
  );
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6FE0)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6FE0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _Start(),
    );
  }
}

class _Start extends ConsumerStatefulWidget {
  const _Start();
  @override
  ConsumerState<_Start> createState() => _StartState();
}

class _StartState extends ConsumerState<_Start> {
  final List<String> _gewaehlt = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Emoji-Picker')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_gewaehlt.join(' '), style: const TextStyle(fontSize: 34)),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('oeffnen'),
              icon: const Icon(Icons.add_reaction_outlined),
              label: const Text('Picker öffnen'),
              onPressed: () => showReactionEmojiPicker(
                context: context,
                ref: ref,
                onSelected: (e) => setState(() => _gewaehlt.add(e)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
