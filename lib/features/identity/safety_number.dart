// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha512.dart';

/// Signal-style **safety number**: a stable 60-digit fingerprint derived from
/// two users' long-term identity public keys. Both parties compute the exact
/// same number (the inputs are sorted canonically), so they can compare it in
/// person / over a trusted channel to confirm no server sits in the middle
/// (audit C1).
///
/// The number is a slow, iterated SHA-512 over `label ‖ keyLow ‖ keyHigh`, then
/// sliced into twelve 5-digit groups. Iteration makes brute-forcing a colliding
/// key pair costly; sorting the two keys makes the result independent of which
/// side computes it.
class SafetyNumber {
  static const int _iterations = 5200;
  static const String _label = 'chattr-safety-number-v1';

  /// The raw 60-digit safety number for two base64 identity public keys.
  static String compute(String identityA, String identityB) {
    final a = base64.decode(identityA);
    final b = base64.decode(identityB);
    final aFirst = _lexLess(a, b);
    final low = aFirst ? a : b;
    final high = aFirst ? b : a;

    final seed = Uint8List.fromList([...utf8.encode(_label), ...low, ...high]);
    final digest = SHA512Digest();
    var h = seed;
    for (var i = 0; i < _iterations; i++) {
      digest.reset();
      final out = Uint8List(64);
      digest.update(h, 0, h.length);
      digest.doFinal(out, 0);
      h = out;
    }

    final sb = StringBuffer();
    for (var group = 0; group < 12; group++) {
      final off = group * 5;
      var n = 0;
      for (var i = 0; i < 5; i++) {
        n = n * 256 + h[off + i];
      }
      sb.write((n % 100000).toString().padLeft(5, '0'));
    }
    return sb.toString();
  }

  /// The safety number grouped for display: twelve space-separated 5-digit
  /// blocks (e.g. `"01234 56789 …"`).
  static String formatted(String identityA, String identityB) {
    final raw = compute(identityA, identityB);
    final groups = <String>[];
    for (var i = 0; i < raw.length; i += 5) {
      groups.add(raw.substring(i, i + 5));
    }
    return groups.join(' ');
  }

  static bool _lexLess(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.length < b.length;
  }
}
