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

  /// The canonical text style for an initials avatar of a given [radius] on
  /// [background]. ONE style for every surface: the letter is contrast-picked
  /// via [foregroundOn] and scales with the circle (0.8 × radius), mirroring the
  /// chatview fork's in-package circles (`profile_image_widget.dart`, p21).
  ///
  /// Before this existed each call site rolled its own: the chat list hardcoded
  /// `fontSize: 16`, [UserAvatar] and the ChatAvatar fallback set no size at all
  /// (a ~14sp letter lost inside an r=56 circle), and weights ranged over
  /// bold/w600/none — so the same user looked different on every screen.
  static TextStyle initialsTextStyle(double radius, Color background) =>
      TextStyle(
        color: foregroundOn(background),
        fontWeight: FontWeight.w600,
        fontSize: radius * 0.8,
      );

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

/// Canonical initials for an avatar fallback: first letter of the first and
/// last word (single word → one letter), uppercased. One implementation for
/// every surface — the app previously had three diverging variants (chat list,
/// ChatAvatar single-letter, UserAvatar single-letter).
String initialsFor(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first[0].toUpperCase();
  return (words.first[0] + words.last[0]).toUpperCase();
}
