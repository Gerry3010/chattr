// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' show emojiUpscaledSpans;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// How emoji sit inside running text, per emoji font. Measured with
/// `lib/main_emoji_probe.dart`, never derived: what the layout reserves for
/// an emoji and what the font then draws differ by font and engine.
@immutable
class InlineEmojiTuning {
  const InlineEmojiTuning({
    required this.bubbleFactor,
    this.bubbleTrailingGap = 0,
    this.plainTrailingGap = 0,
  });

  /// Emoji size in a text bubble relative to the text. At the text size they
  /// read as too small.
  final double bubbleFactor;

  /// Space the layout leaves after the drawn emoji beyond what it leaves
  /// before it, as a fraction of the emoji size in a bubble, and of the text
  /// size where emoji keep it (composer, captions). Closed with a negative
  /// letter spacing on the emoji run (Gerry, 2026-10-22: in „🙂“ the gap
  /// before the closing quote looked like a space that was not there).
  /// Two values because the emoji font draws in steps, and the excess is not
  /// proportional to the size.
  final double bubbleTrailingGap;
  final double plainTrailingGap;

  /// Emoji runs in a text bubble whose text is [textSize] large.
  TextStyle bubbleStyle(double textSize) {
    final size = textSize * bubbleFactor;
    return TextStyle(
      fontSize: size,
      letterSpacing: bubbleTrailingGap == 0 ? null : -bubbleTrailingGap * size,
    );
  }

  /// Emoji runs that keep the text size (composer, captions): only the gap
  /// correction. Null when there is nothing to correct, so callers leave the
  /// text in one piece.
  TextStyle? plainStyle(double textSize) => plainTrailingGap == 0
      ? null
      : TextStyle(letterSpacing: -plainTrailingGap * textSize);
}

/// Noto Color Emoji (Android, Linux). Drawn evenly inside its box: 1.9 px on
/// either side at 14 px, as much as the quotes around it leave anyway, and
/// 16.4 px tall at 1.125x. 1.125 was tuned on the Galaxy (1.4 and 1.25 looked
/// too big).
const notoEmojiTuning = InlineEmojiTuning(bubbleFactor: 1.125);

/// Apple Color Emoji (iOS, macOS), measured on an iPhone 16 Pro (simulator
/// and device agree to the digit, 2026-10-24). It draws smaller than its
/// size and sits at the left of a box that is too wide: at 14 px the ink is
/// 13 px tall, with 2.0 px before it and 5.3 px after.
/// - 1.25x draws 16.3 px tall, the size Noto has at 1.125x.
/// - The excess after it is 3.0 px at 17.5 px in the bubble (2.7 with
///   Nunito), 0.16 em; at text size (composer 16 px, caption 15 px) 3.0 to
///   3.3 px, 0.2 em.
const appleEmojiTuning = InlineEmojiTuning(
  bubbleFactor: 1.25,
  bubbleTrailingGap: 0.16,
  plainTrailingGap: 0.2,
);

InlineEmojiTuning inlineEmojiTuningFor(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
        ? appleEmojiTuning
        : notoEmojiTuning;

/// [InlineEmojiTuning.bubbleStyle] for this platform's emoji font.
TextStyle bubbleEmojiStyle(double textSize, {TargetPlatform? platform}) =>
    inlineEmojiTuningFor(platform ?? defaultTargetPlatform)
        .bubbleStyle(textSize);

/// [InlineEmojiTuning.plainStyle] for this platform's emoji font.
TextStyle? plainEmojiStyle(double textSize, {TargetPlatform? platform}) =>
    inlineEmojiTuningFor(platform ?? defaultTargetPlatform)
        .plainStyle(textSize);

/// The composer's controller: emoji runs get [plainEmojiStyle], split the
/// same way the bubble splits them (chatview p27/p29), so what you type looks
/// like what you send. Text being composed by the keyboard (an IME's marked
/// range) keeps the default rendering with its underline.
class EmojiTextEditingController extends TextEditingController {
  EmojiTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final emoji = plainEmojiStyle(
      style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 16,
    );
    if (emoji == null || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(
      style: style,
      children: emojiUpscaledSpans(text, emojiStyle: emoji),
    );
  }
}
