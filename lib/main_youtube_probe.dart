// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// **Test entry point for the inline YouTube player — not part of the app.**
///
/// Gerry, 2026-10-22, on the iPhone: a YouTube video in the chat drew over
/// the chat's app bar and the status bar. The player paints its webview
/// through an overlay, and it used to land in the Navigator's overlay above
/// the whole page. This page puts one YouTube bubble into a reversed list
/// under a solid red app bar, the way the chat lays it out, so a screenshot
/// answers the question without sign-in or a chat: tap the poster, scroll
/// the bubble up under the bar, and no video pixel may show in the red.
///
/// ```bash
/// flutter run -d <device> -t lib/main_youtube_probe.dart
/// ```
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/notifications/active_chat_provider.dart';
import 'features/media/widgets/inline_link_video_player.dart';
import 'features/media/widgets/pip_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  runApp(EasyLocalization(
    supportedLocales: const [Locale('de', 'DE'), Locale('en', 'US')],
    path: 'assets/translations',
    fallbackLocale: const Locale('de', 'DE'),
    // The bubble's chat counts as open, as it would be in the app; docking
    // back from the floating window otherwise asks the chat list first.
    child: ProviderScope(
      overrides: [activeChatProvider.overrideWith((ref) => 'probe')],
      child: const _Probe(),
    ),
  ));
}

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        // The floating window the bar's buttons open (PiP, fullscreen).
        builder: (context, child) => PipOverlayHost(child: child!),
        home: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFFF0000),
            title: const Text('Kopfleiste'),
          ),
          body: ListView(
            reverse: true,
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < 12; i++) _filler(i),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 280,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const InlineLinkVideoPlayer.youtube(
                      youtubeId: 'aqz-KE-bpKQ',
                      thumbnailUrl:
                          'https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg',
                      chatId: 'probe',
                      messageId: 'probe-yt',
                      textColor: Colors.black87,
                    ),
                  ),
                ),
              ),
              for (var i = 12; i < 30; i++) _filler(i),
            ],
          ),
        ),
      );

  Widget _filler(int i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFFDDEEDD),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('Nachricht $i'),
        ),
      );
}
