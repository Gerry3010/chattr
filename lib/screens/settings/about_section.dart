// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/updates/android_update_service.dart';
import '../../core/updates/web_update_service.dart';
import '../../features/whats_new/whats_new_store.dart';
import '../whats_new/whats_new_dialog.dart';
import 'changelog_screen.dart';

/// Public site. Also the host that serves the Android update manifest, so a
/// user who wants the APK by hand ends up in the right place.
const _homepageUrl = 'https://chattr.at';

/// "About" — manual update check, changelog, homepage. Room for FAQ later.
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  bool _checking = false;

  /// Only Android (sideloaded APK) and web have an update channel we control.
  /// iOS goes through the App Store and desktop isn't published — offering a
  /// button that can never find anything would be worse than having none.
  bool get _canCheckForUpdates => kIsWeb || isAndroidUpdateTarget;

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      if (kIsWeb) {
        await ref.read(webUpdateServiceProvider).checkNow();
      } else {
        await ref.read(androidUpdateServiceProvider).checkNow();
      }
      if (!mounted) return;

      // The reply carries the ACTION, it does not delegate it.
      //
      // This used to say "update available" and leave the installing to the
      // banner raised by AndroidUpdateListener. That banner only appears on the
      // null → found transition, so a second check — the very thing a user does
      // when the first one seemed to do nothing — reported a find and offered
      // no way to act on it. Reported from a real device (SeB, 2026-08-07):
      // "the update button says 'update available', that's it".
      //
      // Whoever taps "check for updates" asked for the action HERE, so it
      // belongs here. The banner stays as it is for finds the user did not ask
      // for.
      final androidInfo =
          kIsWeb ? null : ref.read(androidUpdateAvailableProvider);
      final found = kIsWeb
          ? ref.read(webUpdateAvailableProvider)
          : androidInfo != null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(found
              ? 'settings.about.update_found'.tr()
              : 'settings.about.up_to_date'.tr()),
          duration: found
              ? const Duration(seconds: 10)
              : const Duration(seconds: 4),
          action: androidInfo == null
              ? null
              : SnackBarAction(
                  label: 'app_update.update'.tr(),
                  onPressed: () => ref
                      .read(androidUpdateServiceProvider)
                      .downloadAndInstall(androidInfo),
                ),
        ));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openHomepage() async {
    final ok = await launchUrl(
      Uri.parse(_homepageUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text('settings.about.open_failed'.tr())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            'settings.about.section'.tr(),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),
        if (_canCheckForUpdates)
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text('settings.about.check_update'.tr()),
            subtitle: Text('settings.about.check_update_hint'.tr()),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _checking ? null : _checkForUpdates,
          ),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text('settings.about.changelog'.tr()),
          subtitle: Text('settings.about.changelog_hint'.tr()),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            appPageRoute<void>(builder: (_) => const ChangelogScreen()),
          ),
        ),
        ListTile(
          key: const ValueKey('whats_new_reset'),
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text('whats_new.reset'.tr()),
          subtitle: Text('whats_new.reset_hint'.tr()),
          onTap: () async {
            await ref.read(whatsNewStoreProvider).reset();
            if (context.mounted) await showWhatsNewIfUnread(context, ref);
          },
        ),
        ListTile(
          leading: const Icon(Icons.public),
          title: Text('settings.about.homepage'.tr()),
          subtitle: const Text('chattr.at'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: _openHomepage,
        ),
      ],
    );
  }
}
