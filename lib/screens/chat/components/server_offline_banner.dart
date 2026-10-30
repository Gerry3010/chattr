// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/events/event_bus_provider.dart';
import '../../../core/events/event_bus_service.dart';
import '../../../core/network/device_connectivity.dart';

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
enum ServerBannerKind { deviceOffline, serverUnreachable }

/// What the banner says, or null while it stays hidden. A provider rather than
/// a check inside the widget, because the chat view has to know whether the
/// banner already took the status-bar inset (TopBannerColumn).
final serverBannerProvider = Provider<ServerBannerKind?>((ref) {
  // The device having no network at all is said first and plainly (CHAT-63):
  // "server unreachable" in airplane mode pointed at us for something that
  // is the reader's to fix, and it took two failed reconnects to show.
  if (ref.watch(deviceOfflineProvider)) return ServerBannerKind.deviceOffline;
  final connection = ref.watch(serverConnectionProvider).asData?.value;
  return connection == ServerConnection.unreachable
      ? ServerBannerKind.serverUnreachable
      : null;
});

class ServerOfflineBanner extends ConsumerWidget {
  const ServerOfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(serverBannerProvider);
    if (kind == null) return const SizedBox.shrink();
    final deviceOffline = kind == ServerBannerKind.deviceOffline;
    final title = deviceOffline
        ? 'server_status.device_offline_title'
        : 'server_status.offline_title';
    final body = deviceOffline
        ? 'server_status.device_offline_body'
        : 'server_status.offline_body';

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
              Icon(
                  deviceOffline
                      ? Icons.signal_wifi_off_outlined
                      : Icons.cloud_off_outlined,
                  size: 20,
                  color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.tr(),
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body.tr(),
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
