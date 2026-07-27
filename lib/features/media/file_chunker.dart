// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Streams a large file from disk in fixed-size plaintext chunks so the whole
/// file never sits in RAM (chunked media send, backlog large-file-chunking).
/// Native reads via `dart:io`; the web has no file paths (large chunked sends
/// are native-only), so the web build gets a stub that throws.
library;

export 'file_chunker_io.dart' if (dart.library.html) 'file_chunker_web.dart';
