// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// The slot to the left of the send button in the send sheet: either the
/// caption field or — for a shot — the note that there is no caption here.
///
/// **Why this is ONE widget and not two.** Both states sit in the same bar, and
/// the bar carries the preview above it. If they are of different heights, the
/// picture jumps when toggling — Gerry saw exactly that on the device
/// (2026-08-28). Two separate widgets drift apart in just that way: one changes
/// a padding and does not notice, because the other state is not visible at the
/// time.
///
/// Here fill, radius and padding therefore stand **once** and apply to both.
/// The note deliberately sets **no font size of its own**, so the line height
/// is the same as in the text field.
class CaptionSlot extends StatelessWidget {
  const CaptionSlot({
    super.key,
    required this.shot,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.shotHintText,
  });

  /// Shot-Modus: Hinweis statt Eingabefeld.
  final bool shot;

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Placeholder in the input field ("add a caption …").
  final String hintText;

  /// The sentence that stands in its place in shot mode.
  final String shotHintText;

  /// Padding — applies to BOTH states. `vertical: 10` plus one line gives the
  /// height the send button beside it aligns to.
  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: 16, vertical: 10);

  static final BorderRadius radius = BorderRadius.circular(24);

  static const Color fill = Colors.white12;

  /// Minimum height of both states.
  ///
  /// Material gives a non-dense `TextField` the height of a tap target (48) —
  /// the padding alone would come to only 40. Those eight pixels were exactly
  /// what made the preview jump. Hence the same constant here rather than a
  /// copied 48: if Material moves the value, both move.
  static const double minHeight = kMinInteractiveDimension;

  @override
  Widget build(BuildContext context) {
    if (!shot) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: false,
        minLines: 1,
        maxLines: 4,
        textInputAction: TextInputAction.newline,
        style: const TextStyle(color: Colors.white),
        cursorColor: Colors.white,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(color: Colors.white54),
          filled: true,
          fillColor: fill,
          contentPadding: padding,
          border: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
        ),
      );
    }
    // NO `alignment` here: a container with alignment expands to the available
    // height — in the test that was promptly 600 instead of 48. The row inside
    // centres itself anyway.
    return Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: padding,
      decoration: BoxDecoration(color: fill, borderRadius: radius),
      child: Row(
        children: [
          Icon(Icons.timer, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              shotHintText,
              // TWO lines, but at the same height: the sentence should break
              // readably (it used to be cut off mid-word), and the bar must
              // still not grow — otherwise the preview jumps again. Both
              // together only work through the font size: 2 × 13.8 points fit
              // into the 28 that remain between the paddings.
              //
              // The ellipsis stays as a net for languages in which even two
              // lines are not enough — better truncated than jumped.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11.5,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
