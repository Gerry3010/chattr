// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../events/event_bus_provider.dart';
import '../events/event_bus_service.dart';
import 'device_connectivity.dart';
import 'network_errors.dart';

/// What a screen shows when its data could not be loaded (CHAT-63).
///
/// Says "keine Verbindung" in words for a network failure instead of a raw
/// exception, offers to retry, and retries on its own once the device has a
/// network again and the server answers. Before, these screens span for ~38 s
/// and then showed `ClientException with SocketException …` until the user
/// left and came back.
class LoadErrorView extends ConsumerWidget {
  const LoadErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback onRetry;

  /// Inside a section of a longer page rather than filling a screen.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isNetworkError(error)) {
      ref.listen<bool>(deviceOfflineProvider, (was, now) {
        if (was == true && !now) onRetry();
      });
      ref.listen<AsyncValue<ServerConnection>>(serverConnectionProvider,
          (was, now) {
        if (was?.value != ServerConnection.connected &&
            now.value == ServerConnection.connected) {
          onRetry();
        }
      });
    }

    final scheme = Theme.of(context).colorScheme;
    final network = isNetworkError(error);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          network ? Icons.cloud_off_outlined : Icons.error_outline,
          size: compact ? 28 : 48,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          userFacingError(error),
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        if (network) ...[
          const SizedBox(height: 4),
          Text(
            'errors.retries_when_online'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text('common.retry'.tr()),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.all(compact ? 16 : 24),
      child: compact ? content : Center(child: content),
    );
  }
}
