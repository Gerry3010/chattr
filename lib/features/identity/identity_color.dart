// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// A deterministic avatar color bound to a peer's cryptographic identity
/// (audit M2 — username impersonation cue).
///
/// Usernames are mutable and non-unique, so two users with the same display
/// name are visually indistinguishable. Deriving the avatar color from the
/// peer's long-term **identity public key** makes them visibly different, and a
/// username swap can no longer also swap the color — it complements (does not
/// replace) the verification shield / safety number. Falls back to the stable
/// `user_id` when a peer hasn't published an identity key yet.
class IdentityColor {
  const IdentityColor._();

  /// Deterministic background color for an identity [seed] (identity pubkey or
  /// user_id). Mid saturation/lightness so it reads on both light and dark
  /// surfaces while leaving contrast for the initial letter.
  static Color forSeed(String seed) {
    final hue = (_fnv1a(seed) % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.55, 0.55).toColor();
  }

  /// Prefer the cryptographic identity key; fall back to the stable user id.
  static Color forKeyOrId(String? identityPublicKey, String userId) => forSeed(
        (identityPublicKey != null && identityPublicKey.isNotEmpty)
            ? identityPublicKey
            : userId,
      );

  /// The maximally-contrasting foreground (black or white) for text/icons drawn
  /// on [background]. Picks whichever gives the higher WCAG contrast ratio — the
  /// crossover is at relative luminance ≈0.179, NOT 0.5, so a plain `>0.5`
  /// threshold would put white text on mid-luminance hues (e.g. amber/green)
  /// where black reads far better. Guarantees a legible initial letter on every
  /// hue.
  static Color foregroundOn(Color background) {
    final lum = background.computeLuminance();
    final contrastWithWhite = 1.05 / (lum + 0.05);
    final contrastWithBlack = (lum + 0.05) / 0.05;
    return contrastWithWhite >= contrastWithBlack ? Colors.white : Colors.black;
  }

  /// FNV-1a 32-bit — a stable, cross-platform string hash. `String.hashCode` is
  /// deliberately NOT stable across runs/platforms, so it can't seed a color
  /// that must be identical on every device showing the same peer.
  static int _fnv1a(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
