// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

// Native (Android/iOS/Linux/macOS/Windows) hybrid KEM via dart:ffi, calling the
// Go c-shared library built from native/chattr_crypto. The wire format is
// identical to the web/JS implementation. Flutter web uses ml_kem_web.dart.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ── C function signatures (see native/chattr_crypto/build/libchattr_crypto.h)

typedef _GenNative = Int32 Function(
    Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Pointer<Uint8>>, Pointer<Int32>);
typedef _GenDart = int Function(
    Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Pointer<Uint8>>, Pointer<Int32>);

typedef _CryptNative = Int32 Function(
    Pointer<Uint8>, Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>);
typedef _CryptDart = int Function(
    Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Int32>);

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

class _Lib {
  _Lib(DynamicLibrary dl)
      : _gen = dl.lookupFunction<_GenNative, _GenDart>('pb_generate_mlkem768'),
        _enc = dl.lookupFunction<_CryptNative, _CryptDart>('pb_encrypt_data_key'),
        _dec = dl.lookupFunction<_CryptNative, _CryptDart>('pb_decrypt_data_key'),
        _free = dl.lookupFunction<_FreeNative, _FreeDart>('pb_free');

  final _GenDart _gen;
  final _CryptDart _enc;
  final _CryptDart _dec;
  final _FreeDart _free;
}

_Lib? _cached;

/// Overrides the library path (used by tests to point at the locally-built .so).
String? mlKemLibraryPathOverride;

_Lib _lib() {
  if (_cached != null) return _cached!;
  final override =
      mlKemLibraryPathOverride ?? Platform.environment['CHATTR_CRYPTO_LIB'];
  final DynamicLibrary dl;
  if (override != null && override.isNotEmpty) {
    dl = DynamicLibrary.open(override);
  } else if (Platform.isAndroid || Platform.isLinux) {
    dl = DynamicLibrary.open('libchattr_crypto.so');
  } else if (Platform.isWindows) {
    dl = DynamicLibrary.open('chattr_crypto.dll');
  } else if (Platform.isMacOS || Platform.isIOS) {
    // Statically linked into the app binary on Apple platforms.
    dl = DynamicLibrary.process();
  } else {
    throw UnsupportedError('No native crypto library for this platform');
  }
  return _cached = _Lib(dl);
}

// ── Helpers ────────────────────────────────────────────────────────────────

Uint8List _readAndFree(_Lib lib, Pointer<Pointer<Uint8>> outPtr, Pointer<Int32> outLen) {
  final ptr = outPtr.value;
  final len = outLen.value;
  final bytes = Uint8List.fromList(ptr.asTypedList(len));
  lib._free(ptr);
  return bytes;
}

Pointer<Uint8> _toNative(Uint8List data) {
  final p = malloc<Uint8>(data.isEmpty ? 1 : data.length);
  if (data.isNotEmpty) p.asTypedList(data.length).setAll(0, data);
  return p;
}

Uint8List _crypt(_CryptDart fn, Uint8List a, Uint8List b, Uint8List c) {
  final lib = _lib();
  final pa = _toNative(a);
  final pb = _toNative(b);
  final pc = _toNative(c);
  final out = malloc<Pointer<Uint8>>();
  final outLen = malloc<Int32>();
  try {
    final rc = fn(pa, a.length, pb, b.length, pc, c.length, out, outLen);
    if (rc != 0) throw StateError('native crypto failed (code $rc)');
    return _readAndFree(lib, out, outLen);
  } finally {
    malloc.free(pa);
    malloc.free(pb);
    malloc.free(pc);
    malloc.free(out);
    malloc.free(outLen);
  }
}

// ── Public API (mirrors ml_kem_web.dart) ─────────────────────────────────────

/// Generates a fresh ML-KEM-768 keypair as (privateKey, publicKey).
Future<(Uint8List, Uint8List)> mlKemGenerate() async {
  final lib = _lib();
  final outPriv = malloc<Pointer<Uint8>>();
  final outPrivLen = malloc<Int32>();
  final outPub = malloc<Pointer<Uint8>>();
  final outPubLen = malloc<Int32>();
  try {
    final rc = lib._gen(outPriv, outPrivLen, outPub, outPubLen);
    if (rc != 0) throw StateError('ml-kem keygen failed (code $rc)');
    final priv = _readAndFree(lib, outPriv, outPrivLen);
    final pub = _readAndFree(lib, outPub, outPubLen);
    return (priv, pub);
  } finally {
    malloc.free(outPriv);
    malloc.free(outPrivLen);
    malloc.free(outPub);
    malloc.free(outPubLen);
  }
}

/// Wraps [dataKey] for a recipient (hybrid X25519 + ML-KEM, with X25519-only
/// fallback when [recipMlkemPub] is not a valid key). Returns the wire blob.
Future<Uint8List> mlKemEncryptDataKey(
        Uint8List dataKey, Uint8List recipX25519Pub, Uint8List recipMlkemPub) async =>
    _crypt(_lib()._enc, dataKey, recipX25519Pub, recipMlkemPub);

/// Unwraps a data key, auto-detecting hybrid vs. legacy X25519-only formats.
Future<Uint8List> mlKemDecryptDataKey(
        Uint8List encKey, Uint8List privX25519, Uint8List privMlkem) async =>
    _crypt(_lib()._dec, encKey, privX25519, privMlkem);
