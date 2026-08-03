// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

// Platform-agnostic hybrid KEM (X25519 + ML-KEM-768). Resolves to the native
// dart:ffi implementation on mobile/desktop and the dart:js_interop (JS) one on
// web. Both expose the same async API and identical wire format:
//   Future<(Uint8List priv, Uint8List pub)> mlKemGenerate()
//   Future<Uint8List> mlKemEncryptDataKey(dataKey, recipX25519Pub, recipMlkemPub)
//   Future<Uint8List> mlKemDecryptDataKey(encKey, privX25519, privMlkem)
//
// Vendored/adapted from the author's passbubble crypto core; the native library
// is built from native/chattr_crypto (see native/build.sh).
export 'ml_kem_ffi.dart' if (dart.library.js_interop) 'ml_kem_web.dart';
