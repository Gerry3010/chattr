// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Turns decrypted media bytes into a URI media_kit can open.
///
/// Native (Linux/Android/iOS/…): writes the bytes to a private temp-cache file
/// and returns its path; the file is deleted again on `VideoSource.dispose`.
/// Web: wraps the bytes in a Blob object URL (no disk); revoked on dispose.
library;

export 'video_source_io.dart'
    if (dart.library.html) 'video_source_web.dart';
