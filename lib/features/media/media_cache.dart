// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Purges the decrypted-media temp-cache (audit M8).
///
/// Native players (media_kit/libmpv) can't play from memory, so incoming media
/// is decrypted to a short-lived file under `<temp>/chattr_media`. Those files
/// are deleted on player dispose, but a crash, logout, or account switch could
/// leave plaintext media on disk. [purgeMediaCache] wipes the whole dir; it's
/// called on wipe/logout and at startup. Web keeps nothing on disk (Blob URLs),
/// so its implementation is a no-op.
library;

export 'media_cache_io.dart' if (dart.library.html) 'media_cache_web.dart';
