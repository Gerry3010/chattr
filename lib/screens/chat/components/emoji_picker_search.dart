// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../../../features/reactions/emoji_search.dart';

/// The search in the emoji picker.
///
/// Built through `SearchViewConfig.customSearchView` — our own rather than the
/// package's version for two reasons:
///
/// 1. **The package's cache goes stale.** `EmojiPickerUtils` is a singleton and
///    memorises the emoji set on the first search forever; after a skin-tone or
///    language change the search went on serving the old one. See `findEmoji`.
/// 2. **The field sat at the bottom, the hits lay above it as a narrow band.**
///    Our header is at the top, so the search field belongs there too — and the
///    hits into the same grid as everywhere else, rather than into a single row
///    one has to scroll sideways through.
class ChattrEmojiSearchView extends SearchView {
  /// Konstruktor.
  const ChattrEmojiSearchView(
    super.config,
    super.state,
    super.showEmojiView, {
    super.key,
  });

  @override
  ChattrEmojiSearchViewState createState() => ChattrEmojiSearchViewState();
}

/// Zustand zu [ChattrEmojiSearchView].
class ChattrEmojiSearchViewState
    extends SearchViewState<ChattrEmojiSearchView> {
  String _input = '';

  @override
  void onTextInputChanged(String text) {
    links.clear();
    setState(() {
      _input = text;
      results
        ..clear()
        ..addAll(findEmoji(text, widget.state.categoryEmoji));
      for (final e in results) {
        links[e.emoji] = LayerLink();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final emojiSize =
            widget.config.emojiViewConfig.getEmojiSize(constraints.maxWidth);
        final emojiBoxSize =
            widget.config.emojiViewConfig.getEmojiBoxSize(constraints.maxWidth);

        return ColoredBox(
          color: widget.config.searchViewConfig.backgroundColor,
          child: Column(
            children: [
              Material(
                color: Colors.transparent,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: widget.showEmojiView,
                      color: widget.config.searchViewConfig.buttonIconColor,
                      tooltip: MaterialLocalizations.of(context)
                          .backButtonTooltip,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: TextField(
                        onChanged: onTextInputChanged,
                        focusNode: focusNode,
                        style: widget.config.searchViewConfig.inputTextStyle,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'emoji_picker.search'.tr(),
                          hintStyle:
                              widget.config.searchViewConfig.hintTextStyle,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _matches(emojiSize, emojiBoxSize, colors)),
            ],
          ),
        );
      },
    );
  }

  Widget _matches(double emojiSize, double emojiBoxSize, ColorScheme colors) {
    // Before the first input the base class fills `results` with the history —
    // which is exactly right as a starting point and needs no hint text.
    if (_input.isNotEmpty && results.isEmpty) {
      return Center(
        child: Text(
          'emoji_picker.no_results'.tr(),
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      padding: widget.config.emojiViewConfig.gridPadding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        childAspectRatio: 1,
        crossAxisCount: widget.config.emojiViewConfig.columns,
        mainAxisSpacing: widget.config.emojiViewConfig.verticalSpacing,
        crossAxisSpacing: widget.config.emojiViewConfig.horizontalSpacing,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) =>
          buildEmoji(results[index], emojiSize, emojiBoxSize),
    );
  }
}
