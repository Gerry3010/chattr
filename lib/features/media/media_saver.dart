// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Save (download on web) or share (mobile/desktop) decrypted media bytes.
library;

export 'media_saver_io.dart'
    if (dart.library.html) 'media_saver_web.dart';
