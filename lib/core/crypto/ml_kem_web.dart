// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

// Web hybrid KEM via dart:js_interop, calling the JS implementation bundled from
// web_crypto (packages: mlkem, @noble/curves + Web Crypto API). The bundle
// exposes globalThis.chattrCrypto and is loaded from web/index.html. The wire
// format matches the native FFI library. dart:ffi is unavailable on web, which
// is why this separate implementation exists (see ml_kem.dart).

import 'dart:js_interop';
import 'dart:typed_data';

@JS('chattrCrypto.generateMlKem768')
external JSPromise<JSObject> _generate();

@JS('chattrCrypto.encryptDataKey')
external JSPromise<JSUint8Array> _encrypt(JSUint8Array dataKey, JSUint8Array pubX, JSUint8Array pubM);

@JS('chattrCrypto.decryptDataKey')
external JSPromise<JSUint8Array> _decrypt(JSUint8Array encKey, JSUint8Array privX, JSUint8Array privM);

extension type _KeyPair(JSObject _) implements JSObject {
  external JSUint8Array get priv;
  external JSUint8Array get pub;
}

/// Generates a fresh ML-KEM-768 keypair as (privateKey, publicKey).
Future<(Uint8List, Uint8List)> mlKemGenerate() async {
  final kp = _KeyPair(await _generate().toDart);
  return (kp.priv.toDart, kp.pub.toDart);
}

/// Wraps [dataKey] for a recipient (hybrid X25519 + ML-KEM, with X25519-only
/// fallback when [recipMlkemPub] is not a valid key).
Future<Uint8List> mlKemEncryptDataKey(
    Uint8List dataKey, Uint8List recipX25519Pub, Uint8List recipMlkemPub) async {
  final out = await _encrypt(dataKey.toJS, recipX25519Pub.toJS, recipMlkemPub.toJS).toDart;
  return out.toDart;
}

/// Unwraps a data key, auto-detecting hybrid vs. legacy X25519-only formats.
Future<Uint8List> mlKemDecryptDataKey(
    Uint8List encKey, Uint8List privX25519, Uint8List privMlkem) async {
  final out = await _decrypt(encKey.toJS, privX25519.toJS, privMlkem.toJS).toDart;
  return out.toDart;
}
