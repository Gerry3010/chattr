// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/chat_view/chat_view_reactions_adapter.dart';
import '../../../features/messages/message_model.dart';
import '../../../features/messages/message_reaction_model.dart';
import '../../../features/messages/message_reactions_controller.dart';
import '../../../features/messages/messages_controller.dart';
import '../favorites_screen.dart' show favoriteMessagesProvider;

/// Quick reactions offered at the top of the actions sheet. These are the
/// exact code points chatview's reaction popup used before, so tapping the
/// same emoji again toggles reactions that were stored earlier.
const List<String> quickReactionEmojis = [
  '\u{2764}', // ❤ heart
  '\u{1F602}', // 😂 face with tears
  '\u{1F632}', // 😲 astonished
  '\u{1F625}', // 😥 disappointed
  '\u{1F621}', // 😡 angry
  '\u{1F44D}', // 👍 thumbs up
];

/// The unified message actions menu (long-press / double-tap on a bubble):
/// a quick-reaction row on top, followed by the actions that apply to the
/// message. Pass `null` for an action to hide its entry.
Future<void> showMessageActionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String chatId,
  required chatview.Message message,
  VoidCallback? onReply,
  VoidCallback? onForward,
  VoidCallback? onEdit,
  VoidCallback? onUnsend,
  VoidCallback? onInfo,
  VoidCallback? onReport,
  String? copyText,
}) {
  final adapter = ChatViewReactionsAdapter(ref, chatId);
  // Emojis the current user has already reacted with (for highlighting).
  final ownReactions = (ref.read(chatReactionsProvider(chatId))[message.id] ??
          const <ReactionSummary>[])
      .where((s) => s.userReacted)
      .map((s) => s.reaction)
      .toSet();
  // The app-side message (for the local favorite flag, #4). Sheet is transient,
  // so a one-shot read is fine.
  final appMessage = ref
      .read(messagesControllerProvider(chatId))
      .where((m) => m.id == message.id)
      .whereType<Message>()
      .cast<Message?>()
      .firstWhere((m) => true, orElse: () => null);
  final isFavorite = appMessage?.isFavorite ?? false;

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final emoji in quickReactionEmojis)
                    _QuickReactionButton(
                      emoji: emoji,
                      selected: ownReactions.contains(emoji),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        adapter.onReactionTap(
                          messageId: message.id,
                          emoji: emoji,
                        );
                      },
                    ),
                  // "+" → full emoji picker for any custom reaction beyond the
                  // six quick presets. Toggles via the same onReactionTap.
                  _MoreReactionsButton(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showReactionEmojiPicker(
                        context: context,
                        onSelected: (emoji) => adapter.onReactionTap(
                          messageId: message.id,
                          emoji: emoji,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (onReply != null)
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text('chat_view.reply'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                onReply();
              },
            ),
          if (copyText != null)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text('chat_view.copy'.tr()),
              onTap: () async {
                Navigator.pop(sheetContext);
                await Clipboard.setData(ClipboardData(text: copyText));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('chat_view.copied'.tr())),
                  );
                }
              },
            ),
          if (onForward != null)
            ListTile(
              leading: const Icon(Icons.forward),
              title: Text('chat_view.forward'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                onForward();
              },
            ),
          // Favorite / unfavorite (#4) — only for real (user) messages.
          if (appMessage != null)
            ListTile(
              leading: Icon(isFavorite ? Icons.star : Icons.star_border),
              title: Text((isFavorite
                      ? 'chat_view.unfavorite'
                      : 'chat_view.favorite')
                  .tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                ref
                    .read(messagesControllerProvider(chatId).notifier)
                    .toggleFavorite(appMessage);
                // Keep the (possibly still-mounted) favorites view in sync —
                // it's an autoDispose FutureProvider that otherwise shows a
                // stale snapshot when you pop back to it after toggling.
                ref.invalidate(favoriteMessagesProvider);
              },
            ),
          if (onInfo != null)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('chat_view.message_info'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                onInfo();
              },
            ),
          if (onEdit != null)
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text('chat_view.edit_message'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                onEdit();
              },
            ),
          if (onUnsend != null)
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text(
                'chat_view.delete'.tr(),
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                onUnsend();
              },
            ),
          // Report (data-minimal): only offered for messages the user did NOT
          // send. Files a server report carrying only {message_id, chat_id,
          // reason} — never content (see _reportMessage).
          if (onReport != null)
            ListTile(
              leading: Icon(Icons.flag_outlined, color: Colors.orange[800]),
              title: Text(
                'chat_view.report_message'.tr(),
                style: TextStyle(color: Colors.orange[800]),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                onReport();
              },
            ),
        ],
      ),
    ),
  );
}

/// The emoji-picker tab the user last viewed, remembered for the session only
/// (RAM — deliberately NOT persisted). Starts on Smileys rather than the empty
/// "Recents" tab; then follows wherever the user browses within this run.
Category _lastReactionEmojiCategory = Category.SMILEYS;

/// Opens a full emoji picker so the user can react with ANY emoji, not just the
/// six quick presets. On pick, [onSelected] gets the chosen emoji (the caller
/// toggles it via the same reaction path).
void _showReactionEmojiPicker({
  required BuildContext context,
  required void Function(String emoji) onSelected,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.pop(ctx);
            onSelected(emoji.emoji);
          },
          // Remember the browsed tab for the session (RAM-only).
          onCategoryChanged: (category) =>
              _lastReactionEmojiCategory = category,
          config: Config(
            height: 320,
            // The default renders EVERY emoji once to probe platform support,
            // which lags the open + each tab switch. Android/iOS render the
            // standard set fine, so skip the probe → snappy picker.
            checkPlatformCompatibility: false,
            emojiViewConfig: const EmojiViewConfig(
              backgroundColor: Colors.transparent,
              // Plain gesture cells (no Material ink per emoji) → lighter tree,
              // fewer widgets to build when a big category first paints.
              buttonMode: ButtonMode.NONE,
            ),
            categoryViewConfig: CategoryViewConfig(
              initCategory: _lastReactionEmojiCategory,
              indicatorColor: Theme.of(context).colorScheme.primary,
              iconColorSelected: Theme.of(context).colorScheme.primary,
              backgroundColor: Theme.of(context).colorScheme.surface,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(
              backgroundColor: Theme.of(context).colorScheme.surface,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The "+" entry in the quick-reaction row → opens the full emoji picker.
class _MoreReactionsButton extends StatelessWidget {
  final VoidCallback onTap;

  const _MoreReactionsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        child: Icon(
          Icons.add_reaction_outlined,
          size: 28,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _QuickReactionButton extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  const _QuickReactionButton({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: selected
            ? BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              )
            : null,
        // Scoped emoji-font fallback: Linux desktop won't pick a color emoji
        // font on its own, so these rendered as dark monochrome glyphs.
        // Kept OFF the global theme deliberately — Noto Color Emoji ships
        // wide space/digit glyphs that wreck ordinary text spacing. Platforms
        // without the font (Android/iOS/web) skip the fallback entry.
        child: Text(
          emoji,
          style: const TextStyle(
            fontSize: 28,
            fontFamilyFallback: ['Noto Color Emoji'],
          ),
        ),
      ),
    );
  }
}
