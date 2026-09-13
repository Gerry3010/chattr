// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

/// A text block on a photo shot.
///
/// **Why the position is a fraction and not pixels.** The preview measures in
/// logical pixels, the burning happens in image pixels — the same number exists
/// in both worlds only as a *ratio*. That is exactly what the caption line came
/// to grief on once before (1.27.2: centred in the preview, left in the sent
/// picture); the lesson is that preview and result must do the same arithmetic,
/// not a similar one.
class ShotTextBlock {
  const ShotTextBlock({required this.text, required this.y});

  final String text;

  /// **Centre** of the bar as a fraction of the image height, 0 = topmost, 1 =
  /// bottom. The centre, not the top edge: one taps a point, and the text
  /// should appear where the finger was — not below it.
  final double y;

  ShotTextBlock copyWith({String? text, double? y}) =>
      ShotTextBlock(text: text ?? this.text, y: y ?? this.y);

  @override
  bool operator ==(Object other) =>
      other is ShotTextBlock && other.text == text && other.y == y;

  @override
  int get hashCode => Object.hash(text, y);

  @override
  String toString() => 'ShotTextBlock("$text" @ ${y.toStringAsFixed(3)})';
}

/// More than this is no longer a photo but a wall.
const int kMaxShotTextBlocks = 5;

/// What actually travels into the picture: empty blocks fall away, the position
/// stays inside the picture, and there are no more than [kMaxShotTextBlocks].
///
/// **An empty block disappears silently** — that is deliberate. Whoever types
/// and then thinks better of it should not have to go hunting for a delete
/// button; nothing written means nothing meant.
List<ShotTextBlock> visibleTextBlocks(List<ShotTextBlock> blocks) => [
      for (final b in blocks)
        if (b.text.trim().isNotEmpty)
          b.copyWith(text: b.text.trim(), y: b.y.clamp(0.0, 1.0)),
    ].take(kMaxShotTextBlocks).toList();

/// The top edge of the bar in the same unit as [imageHeight].
///
/// **The one source** for preview and burning. The bar is pushed to the edge
/// rather than allowed to jut past it: a sentence hanging half out of the
/// picture would be half gone at the recipient — and the sender saw all of it.
double shotTextBlockTop({
  required double y,
  required double bandHeight,
  required double imageHeight,
}) {
  final top = y * imageHeight - bandHeight / 2;
  final maximum = math.max(0.0, imageHeight - bandHeight);
  return top.clamp(0.0, maximum);
}
