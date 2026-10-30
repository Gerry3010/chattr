// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Mirror the push-render cache somewhere the web service worker can read it.
///
/// A no-op everywhere except web: on Android the background isolate reads
/// SharedPreferences directly, so there is nothing to mirror.
Future<void> mirrorPushCacheForServiceWorker({
  required Map<String, String> names,
  required Map<String, String> templates,
}) async {}
