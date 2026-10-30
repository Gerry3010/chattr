// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:flutter/material.dart';

/// Where the floating button sits along the bottom of the chat.
enum ChatScrollButtonAlignment { left, center, right }

/// A standalone, self-positioning "jump to end of chat" button.
///
/// Rendered by the app (not chatview's `enableScrollToBottomButton`): with a
/// custom `sendMessageBuilder` the package button lands in a layer whose taps
/// fall through to the message underneath. This one is a normal widget — it
/// reliably absorbs its tap — and owns its own placement, visibility, and theme.
///
/// Drop it into a `Positioned.fill` (or any Stack cell): it aligns itself to the
/// chosen [alignment] just above the composer, fades in once the list is scrolled
/// [showThreshold] px up from the newest message, and hides again at the bottom.
class ChatScrollToBottomButton extends StatefulWidget {
  /// The chatview controller whose `scrollController` drives visibility and whose
  /// `scrollToLastMessage()` the tap invokes.
  final chatview.ChatController chatController;

  /// Horizontal placement along the bottom edge.
  final ChatScrollButtonAlignment alignment;

  /// Button diameter.
  final double size;

  /// Gap above the composer (keeps the button clear of the text field).
  final double bottomOffset;

  /// Side/edge padding.
  final double horizontalPadding;

  /// Scroll distance (px, up from the newest message) before the button appears.
  /// Null → ~0.6 of the viewport height (about "a screen up").
  final double? showThreshold;

  final Color? backgroundColor;

  /// Fully custom icon widget. When null, a themed [Icon] of [iconData] tinted
  /// [iconColor] is used.
  final Widget? icon;
  final IconData iconData;
  final Color? iconColor;

  const ChatScrollToBottomButton({
    super.key,
    required this.chatController,
    this.alignment = ChatScrollButtonAlignment.right,
    this.size = 40,
    this.bottomOffset = 88,
    this.horizontalPadding = 12,
    this.showThreshold,
    this.backgroundColor,
    this.icon,
    this.iconData = Icons.keyboard_arrow_down,
    this.iconColor,
  });

  @override
  State<ChatScrollToBottomButton> createState() =>
      _ChatScrollToBottomButtonState();
}

class _ChatScrollToBottomButtonState extends State<ChatScrollToBottomButton> {
  bool _visible = false;

  ScrollController get _sc => widget.chatController.scrollController;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatScrollToBottomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatController != widget.chatController) {
      oldWidget.chatController.scrollController.removeListener(_onScroll);
      _sc.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _sc.removeListener(_onScroll);
    super.dispose();
  }

  double get _threshold =>
      widget.showThreshold ?? MediaQuery.of(context).size.height * 0.6;

  void _onScroll() {
    if (!_sc.hasClients) return;
    // Bottom-anchored list: offset grows as you scroll UP away from the newest.
    final show = _sc.offset > _threshold;
    if (show != _visible && mounted) setState(() => _visible = show);
  }

  Alignment get _alignment => switch (widget.alignment) {
        ChatScrollButtonAlignment.left => Alignment.bottomLeft,
        ChatScrollButtonAlignment.center => Alignment.bottomCenter,
        ChatScrollButtonAlignment.right => Alignment.bottomRight,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // IgnorePointer while hidden so the invisible button never blocks taps on the
    // messages / composer underneath.
    return IgnorePointer(
      ignoring: !_visible,
      child: Align(
        alignment: _alignment,
        child: Padding(
          padding: EdgeInsets.only(
            left: widget.horizontalPadding,
            right: widget.horizontalPadding,
            bottom: widget.bottomOffset,
          ),
          child: AnimatedScale(
            scale: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Material(
              color: widget.backgroundColor ?? scheme.surfaceContainerHighest,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const CircleBorder(),
                // waitFor: zero — the default inserts a timer delay before the
                // scroll starts, which felt like tap lag. Scroll immediately.
                onTap: () => widget.chatController
                    .scrollToLastMessage(waitFor: Duration.zero),
                child: SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: Center(
                    child: widget.icon ??
                        Icon(
                          widget.iconData,
                          color: widget.iconColor ?? scheme.onSurface,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
