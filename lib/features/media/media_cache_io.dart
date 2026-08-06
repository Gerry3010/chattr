// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Name of the temp-cache subdir holding decrypted media files.
/// Shared with [VideoSource] so both write and purge agree on the location.
const String mediaCacheDirName = 'chattr_media';

/// Delete the decrypted-media temp-cache dir and everything in it (audit M8).
/// Best-effort: a leftover file is a privacy issue, not a crash, so failures
/// are swallowed.
Future<void> purgeMediaCache() async {
  try {
    final dir = await getTemporaryDirectory();
    final cache = Directory('${dir.path}/$mediaCacheDirName');
    if (cache.existsSync()) {
      await cache.delete(recursive: true);
    }
  } catch (_) {
    // best-effort
  }
}
