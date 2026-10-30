// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/reactions/chattr_emoji_set.dart';
import '../../../features/reactions/skin_tone_controller.dart';
import 'emoji_picker_header.dart';
import 'emoji_picker_search.dart';

/// The emoji-picker tab the user last viewed, remembered for the session only
/// (RAM — deliberately NOT persisted). Starts on Smileys rather than the empty
/// "Recents" tab; then follows wherever the user browses within this run.
Category _lastReactionEmojiCategory = Category.SMILEYS;

/// ONE fixed function for `Config.emojiSet` per skin tone.
///
/// `Config` compares itself via `==`, and `emojiSet` is part of that
/// comparison. A freshly built closure is a different one on every build → the
/// picker would consider its configuration changed, throw the emoji set away
/// and rebuild it, on every single build. Hence memoised.
final Map<String, List<CategoryEmoji> Function(Locale)> _emojiSetBuilders =
    {};

List<CategoryEmoji> Function(Locale) _emojiSetFor(String skinTone) =>
    _emojiSetBuilders.putIfAbsent(
      skinTone,
      () =>
          (locale) => chattrEmojiSet(locale, skinTone: skinTone),
    );

/// The height of the sheet — normal and with the keyboard up.
const double _height = 320;
const double _heightWithKeyboard = 160;

/// Opens a full emoji picker so the user can react with ANY emoji, not just the
/// six quick presets. On pick, [onSelected] gets the chosen emoji (the caller
/// toggles it via the same reaction path).
void showReactionEmojiPicker({
  required BuildContext context,
  required WidgetRef ref,
  required void Function(String emoji) onSelected,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final colors = Theme.of(ctx).colorScheme;
      // The sheet has a fixed height and sticks to the bottom edge — so the
      // keyboard laid itself over the search field AND the results. And it does
      // not come occasionally but always: the search view sets the focus itself
      // on opening. `viewInsets.bottom` is 0 without a keyboard, so the padding
      // costs nothing in the normal case.
      final keyboard = MediaQuery.viewInsetsOf(ctx).bottom > 0;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: SizedBox(
            // Half the height with the keyboard up: merely giving way was
            // enough, but it stacked a full sheet PLUS keyboard on top of each
            // other and left almost nothing of the chat — while the result list
            // inside it stood half empty. Whoever is searching only looks at
            // the top rows anyway.
            height: keyboard ? _heightWithKeyboard : _height,
            // The skin tone is watched here so that a change recolours the grid
            // at once, without closing the sheet.
            child: Consumer(
              builder: (ctx, ref, _) {
                final skinTone = ref.watch(skinToneProvider);
                return EmojiPicker(
                  // Rebuild the picker entirely on a skin-tone change: its
                  // `didUpdateWidget` does see the new configuration, but the
                  // key makes it independent of whatever the package compares
                  // in future.
                  key: ValueKey('emoji-picker-$skinTone'),
                  onEmojiSelected: (category, emoji) {
                    Navigator.pop(ctx);
                    onSelected(emoji.emoji);
                  },
                  // Remember the browsed tab for the session (RAM-only).
                  onCategoryChanged: (category) =>
                      _lastReactionEmojiCategory = category,
                  config: Config(
                    // Deliberately WITHOUT a height of its own: otherwise the
                    // package would put the picker into a second fixed height,
                    // and `Config` compares itself via `==` — every change to
                    // it rebuilds the picker completely. Right as the keyboard
                    // comes up that would mean: search view gone, typed text
                    // gone, keyboard closed, height back, and from the top
                    // again. The height therefore belongs to the sheet around
                    // it alone.
                    height: null,
                    // The default renders EVERY emoji once to probe platform
                    // support, which lags the open + each tab switch.
                    // Android/iOS render the standard set fine, so skip the
                    // probe → snappy picker.
                    checkPlatformCompatibility: false,
                    // The package set, supplemented by the roughly 285 emoji it
                    // lacks (🪦, 🩷, 🫀 …) — see chattr_emoji_set.dart.
                    emojiSet: _emojiSetFor(skinTone),
                    // Without this English applies, and the package's German
                    // search terms would lie around unused.
                    locale: context.locale,
                    emojiViewConfig: const EmojiViewConfig(
                      backgroundColor: Colors.transparent,
                      // Plain gesture cells (no Material ink per emoji) →
                      // lighter tree, fewer widgets to build when a big category
                      // first paints.
                      buttonMode: ButtonMode.NONE,
                    ),
                    categoryViewConfig: CategoryViewConfig(
                      initCategory: _lastReactionEmojiCategory,
                      indicatorColor: colors.primary,
                      iconColorSelected: colors.primary,
                      backgroundColor: colors.surface,
                      customCategoryView: (config, state, tabs, pages) =>
                          ChattrEmojiCategoryBar(
                            config,
                            state,
                            tabs,
                            pages,
                            skinTone: skinTone,
                            onSkinTone: (String t) =>
                                ref.read(skinToneProvider.notifier).setTone(t),
                          ),
                    ),
                    // The search now sits in the header — the bottom bar would
                    // only bring the backspace key along, which a reaction does
                    // not need.
                    bottomActionBarConfig: const BottomActionBarConfig(
                      enabled: false,
                    ),
                    skinToneConfig: SkinToneConfig(
                      dialogBackgroundColor: colors.surfaceContainerHigh,
                      indicatorColor: colors.outline,
                    ),
                    searchViewConfig: SearchViewConfig(
                      backgroundColor: colors.surface,
                      buttonIconColor: colors.onSurfaceVariant,
                      customSearchView: ChattrEmojiSearchView.new,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
