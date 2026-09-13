// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_update_service.dart';

/// Starts the Android APK update checker and surfaces "new version available"
/// as a MaterialBanner. Tapping "update" downloads the APK (with a progress
/// banner) and hands it to the system installer; a browser download is offered
/// if that fails. No-op on every non-Android platform.
class AndroidUpdateListener extends ConsumerStatefulWidget {
  final Widget child;

  const AndroidUpdateListener({super.key, required this.child});

  @override
  ConsumerState<AndroidUpdateListener> createState() =>
      _AndroidUpdateListenerState();
}

class _AndroidUpdateListenerState extends ConsumerState<AndroidUpdateListener> {
  @override
  void initState() {
    super.initState();
    ref.read(androidUpdateServiceProvider).start();
  }

  void _showAvailable(AndroidUpdateInfo info) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.system_update_alt),
        content: Text('app_update.available'.tr()),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(androidUpdateServiceProvider).downloadAndInstall(info),
            child: Text('app_update.update'.tr()),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              ref.read(androidUpdateAvailableProvider.notifier).state = null;
            },
            child: Text('app_update.later'.tr()),
          ),
        ],
      ),
    );
  }

  void _showProgress() {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.downloading),
        content: const _ProgressContent(),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: Text('app_update.hide'.tr()),
          ),
        ],
      ),
    );
  }

  void _showFailed() {
    final info = ref.read(androidUpdateAvailableProvider);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.error_outline),
        content: Text('app_update.download_failed'.tr()),
        actions: [
          if (info != null)
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                launchUrl(
                  Uri.parse(info.apkUrl),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: Text('app_update.open_in_browser'.tr()),
            ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              ref.read(androidUpdateServiceProvider).resetProgress();
            },
            child: Text('app_update.dismiss'.tr()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AndroidUpdateInfo?>(androidUpdateAvailableProvider,
        (previous, info) {
      if (info != null && previous == null) _showAvailable(info);
    });
    ref.listen<AndroidUpdateProgress>(androidUpdateProgressProvider,
        (previous, next) {
      if (next.phase == AndroidUpdatePhase.downloading &&
          previous?.phase != AndroidUpdatePhase.downloading) {
        _showProgress();
      } else if (next.phase == AndroidUpdatePhase.failed) {
        _showFailed();
      } else if (next.phase == AndroidUpdatePhase.launching) {
        // System installer is up — get out of the way.
        ScaffoldMessenger.of(context).clearMaterialBanners();
      }
    });
    return widget.child;
  }
}

/// Live download status inside the progress banner.
class _ProgressContent extends ConsumerWidget {
  const _ProgressContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(androidUpdateProgressProvider);
    final verifying = p.phase == AndroidUpdatePhase.verifying;
    final pct = (p.progress.clamp(0.0, 1.0) * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(verifying
            ? 'app_update.verifying'.tr()
            : 'app_update.downloading'.tr(namedArgs: {'p': '$pct'})),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: verifying || p.progress <= 0 ? null : p.progress,
        ),
      ],
    );
  }
}
