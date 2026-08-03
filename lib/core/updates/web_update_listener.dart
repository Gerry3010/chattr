// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'web_update_service.dart';

/// Starts the web update checker and surfaces "new version available" as a
/// MaterialBanner with a reload action. No-op on non-web platforms.
class WebUpdateListener extends ConsumerStatefulWidget {
  final Widget child;

  const WebUpdateListener({super.key, required this.child});

  @override
  ConsumerState<WebUpdateListener> createState() => _WebUpdateListenerState();
}

class _WebUpdateListenerState extends ConsumerState<WebUpdateListener> {
  @override
  void initState() {
    super.initState();
    ref.read(webUpdateServiceProvider).start();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(webUpdateAvailableProvider, (previous, available) {
      if (!available || previous == available) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showMaterialBanner(
        MaterialBanner(
          leading: const Icon(Icons.system_update_alt),
          content: Text('app_update.available'.tr()),
          actions: [
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                reloadPage();
              },
              child: Text('app_update.reload'.tr()),
            ),
            TextButton(
              onPressed: messenger.hideCurrentMaterialBanner,
              child: Text('app_update.later'.tr()),
            ),
          ],
        ),
      );
    });
    return widget.child;
  }
}
