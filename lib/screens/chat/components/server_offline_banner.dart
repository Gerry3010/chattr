// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/events/event_bus_provider.dart';
import '../../../core/events/event_bus_service.dart';

/// "The server is down — your messages are not." Shown across the top of the
/// chat list and of an open chat while the realtime channel cannot get through.
///
/// **Why this exists.** During the 2026-08-04 outage the app simply went quiet:
/// nothing arrived, sending failed, and there was no way to tell an outage from
/// something having gone wrong with your own account or data. That silence is
/// the worst possible answer for an encrypted messenger, where the user's first
/// fear is that their history is gone. So the banner does two jobs, and the
/// second matters more than the first: it names the server as the problem, and
/// it says the local data is fine.
///
/// Only [ServerConnection.unreachable] renders. A single dropped socket is
/// [ServerConnection.reconnecting] and stays invisible — a banner that flashes
/// on every tunnel and Wi-Fi handover teaches people to ignore it, and then it
/// is worth nothing on the day it is true.
class ServerOfflineBanner extends ConsumerWidget {
  const ServerOfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(serverConnectionProvider).asData?.value;
    if (connection != ServerConnection.unreachable) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'server_status.offline_title'.tr(),
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'server_status.offline_body'.tr(),
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
