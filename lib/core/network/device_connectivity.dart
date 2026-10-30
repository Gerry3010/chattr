// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the DEVICE has a network, as opposed to whether our server answers
/// (CHAT-63).
///
/// The realtime channel only knows that it cannot get through, so the app said
/// "Server nicht erreichbar" in airplane mode too. The difference matters to
/// the reader: one is theirs to fix, the other ours. And the channel waited
/// out its backoff (up to 30 s) after the network was back; the platform tells
/// us the moment it is.
///
/// Fails open: when the platform cannot answer (no NetworkManager on a Linux
/// box, tests), the device counts as online and nothing changes from before.
bool isOffline(List<ConnectivityResult> results) =>
    results.isEmpty || results.every((r) => r == ConnectivityResult.none);

/// Whether a network change is a reason to reconnect the realtime channel
/// right away: the device has a network now, and either had none before or
/// the channel is not connected (a Wi-Fi to mobile handover usually kills the
/// socket without the server noticing for a while).
bool reconnectOnNetworkChange({
  required List<ConnectivityResult>? previous,
  required List<ConnectivityResult> next,
  required bool channelConnected,
}) {
  if (isOffline(next)) return false;
  final wasOffline = previous != null && isOffline(previous);
  return wasOffline || !channelConnected;
}

/// Thrown instead of trying the network when the device is known to have
/// none (CHAT-66). postgrest retries a failed GET three times (1 + 2 + 4 s),
/// so a send in airplane mode sat on its clock for seven seconds before it
/// could say it had not gone out.
class DeviceOfflineException implements Exception {
  const DeviceOfflineException();

  @override
  String toString() => 'DeviceOfflineException: the device has no network';
}

/// Raw platform answer. Overridden in tests.
final connectivityResultsProvider =
    StreamProvider<List<ConnectivityResult>>((ref) async* {
  final connectivity = Connectivity();
  try {
    yield await connectivity.checkConnectivity();
  } catch (_) {
    yield const [ConnectivityResult.other];
  }
  yield* connectivity.onConnectivityChanged.handleError((Object _) {});
});

/// How long the device must stay without network before the app says so. A
/// handover between Wi-Fi and mobile reports "none" for a moment, and a banner
/// that flashes on every handover teaches people to ignore it.
const Duration offlineGrace = Duration(seconds: 2);

/// True once the device has had no network for [offlineGrace]; false again
/// the moment it has one.
final deviceOfflineProvider =
    NotifierProvider<DeviceOfflineNotifier, bool>(DeviceOfflineNotifier.new);

class DeviceOfflineNotifier extends Notifier<bool> {
  Timer? _pending;

  @override
  bool build() {
    ref.onDispose(() => _pending?.cancel());
    ref.listen<AsyncValue<List<ConnectivityResult>>>(
      connectivityResultsProvider,
      (_, next) => _apply(next.value),
    );
    // Not via fireImmediately: that would set state inside build.
    final current = ref.read(connectivityResultsProvider).value;
    if (current != null && isOffline(current)) _scheduleOffline();
    return false;
  }

  void _apply(List<ConnectivityResult>? results) {
    if (results == null) return;
    if (isOffline(results)) {
      _scheduleOffline();
    } else {
      _pending?.cancel();
      _pending = null;
      state = false;
    }
  }

  void _scheduleOffline() {
    _pending ??= Timer(offlineGrace, () {
      _pending = null;
      state = true;
    });
  }
}
