// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// APK download+install entry point, split by platform so the web build never
// pulls in `dart:io` / native install plugins.
//
// `dart.library.io` is true on every native target and false on web — the web
// build gets the no-op stub, native gets the real implementation.
export 'apk_installer_stub.dart'
    if (dart.library.io) 'apk_installer_io.dart';
