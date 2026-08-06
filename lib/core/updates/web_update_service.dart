// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;

import '../lifecycle/app_lifecycle_service.dart';
import '../logging/logger_service.dart';

export 'web_reload_stub.dart' if (dart.library.js_interop) 'web_reload_web.dart';

/// Flips to true once a newer web build has been deployed than the one this
/// session started with. The UI (WebUpdateListener) offers a reload.
final webUpdateAvailableProvider = StateProvider<bool>((ref) => false);

/// Session-lifetime service; started once by the UI listener widget.
final webUpdateServiceProvider = Provider<WebUpdateService>((ref) {
  final service = WebUpdateService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Auto-update detection for the web PWA.
///
/// A long-running PWA session never reloads on its own, so a deploy goes
/// unnoticed until the user happens to restart the app. This service fetches
/// `version.json` (emitted by `flutter build web`, deployed alongside the
/// app) at startup as the session baseline, then re-checks periodically and
/// on every app resume. When the served version differs from the baseline it
/// sets [webUpdateAvailableProvider] — the new build is already being
/// downloaded by Flutter's service worker in the background; a reload
/// activates it.
class WebUpdateService {
  final Ref _ref;
  final http.Client _client;
  String? _baseline;
  Timer? _timer;
  StreamSubscription<void>? _resumeSub;
  bool _started = false;

  static const _checkInterval = Duration(minutes: 15);

  WebUpdateService(this._ref, {http.Client? client})
      : _client = client ?? http.Client();

  void start() {
    if (!kIsWeb || _started) return;
    _started = true;
    unawaited(checkNow());
    _timer = Timer.periodic(_checkInterval, (_) => checkNow());
    _resumeSub = _ref
        .read(appLifecycleServiceProvider)
        .onResume
        .listen((_) => checkNow());
  }

  /// One version probe. Called by [start] on startup/interval/resume and by
  /// the manual "check for updates" entry in Settings — no longer test-only.
  Future<void> checkNow() async {
    try {
      // Cache-buster param: deliberately NOT named `v` — Flutter's service
      // worker strips `?v=` and would then serve version.json from its cache,
      // hiding every update. Any other name falls through to the network.
      final uri = Uri.base.resolve(
        'version.json?u=${DateTime.now().millisecondsSinceEpoch}',
      );
      final res =
          await _client.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final version = '${data['version']}+${data['build_number']}';

      // First successful fetch = the version this session was served with.
      if (_baseline == null) {
        _baseline = version;
        return;
      }
      if (version != _baseline) {
        logger.info(
          'Web update available: $_baseline -> $version',
          tag: 'WebUpdate',
        );
        _ref.read(webUpdateAvailableProvider.notifier).state = true;
      }
    } catch (e) {
      // Offline or server hiccup — try again next interval.
      logger.debug('Web update check failed: $e');
    }
  }

  void dispose() {
    _timer?.cancel();
    _resumeSub?.cancel();
  }
}
