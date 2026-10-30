// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/chat_view/chat_view_reactions_adapter.dart';
import '../../../features/messages/message_model.dart';
import '../../../features/messages/message_reaction_model.dart';
import '../../../features/messages/message_reactions_controller.dart';
import '../../../features/messages/messages_controller.dart';
import '../../../features/reactions/chattr_emoji_set.dart';
import '../../../features/reactions/reaction_usage_controller.dart';
import '../../../features/reactions/skin_tone_controller.dart';
import '../../../features/media/shot_envelope.dart';
import 'reaction_emoji_picker.dart';
import '../favorites_screen.dart'
    show chatFavoriteCountProvider, favoriteMessagesProvider;

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
  // What "edit" changes — the message, or only a photo's caption.
  String editLabelKey = 'chat_view.edit_message',
  VoidCallback? onDelete,
  VoidCallback? onInfo,
  VoidCallback? onReport,
  String? copyText,
}) {
  final adapter = ChatViewReactionsAdapter(ref, chatId);
  // Emojis the current user has already reacted with (for highlighting).
  final ownReactions =
      (ref.read(chatReactionsProvider(chatId))[message.id] ??
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

  // The row in the chosen skin tone. Stored bare, shown tinted: the order
  // outlives a change of tone, and a tone is a statement about oneself, not
  // about which emoji one likes.
  //
  // Tinted through the same function the picker uses, so both routes produce
  // the SAME character sequence — a reaction is compared by its text, and a
  // 👍🏽 composed differently could no longer be taken back by tapping.
  //
  // Follows from that: a 👍 reacted with BEFORE a tone was chosen no longer
  // highlights the button, and tapping adds the tinted one beside it. That is
  // right — they are two different reactions — and "remove my reaction" below
  // covers the case.
  final skinTone = ref.read(skinToneProvider);
  final reactionRow = [
    for (final emoji in ref.read(quickReactionRowProvider))
      // `Localizations.localeOf`, not EasyLocalization's `context.locale`:
      // both answer the same in the app (EasyLocalization feeds MaterialApp),
      // and only this one works in a widget test that has no reason to boot
      // the translation machinery just to open a sheet.
      tintEmoji(emoji, skinTone, locale: Localizations.localeOf(context)),
  ];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Without this Flutter limits a bottom sheet to 9/16 of the screen height.
    // The list here is longer: a reaction row plus up to eight entries. What no
    // longer fit was simply CUT OFF — and because nothing scrolled, the last
    // entry was not merely hard to hit but, depending on the device,
    // unreachable altogether. On Gerry's iPhone "delete" stuck exactly on the
    // edge where the home indicator sits.
    //
    // `SafeArea` alone did not help: the inset it adds at the bottom was cut
    // away by the same clipping.
    isScrollControlled: true,
    builder: (sheetContext) => ConstrainedBox(
      // Do not take up the whole screen — the message above should stay
      // visible, otherwise one no longer knows what the action refers to.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
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
                      for (final emoji in reactionRow)
                        _QuickReactionButton(
                          emoji: emoji,
                          selected: ownReactions.contains(emoji),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            adapter.reactOrReport(
                              context,
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
                          showReactionEmojiPicker(
                            context: context,
                            ref: ref,
                            onSelected: (emoji) => adapter.reactOrReport(
                              context,
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
              // Taking a reaction back used to require picking the SAME emoji a
              // second time — which works, but is nowhere labelled, and for an
              // emoji chosen from the picker you first had to find it again.
              // Hidden when there is nothing of yours to remove.
              if (ownReactions.isNotEmpty)
                ListTile(
                  key: const ValueKey('remove_own_reaction_tile'),
                  leading: const Icon(Icons.do_not_disturb_on_outlined),
                  title: Text(
                    ownReactions.length == 1
                        ? 'chat_view.reaction_remove_mine'.tr()
                        : 'chat_view.reaction_remove_mine_all'.tr(),
                  ),
                  // Show WHAT disappears — with several reactions the label alone
                  // would leave you guessing.
                  trailing: Text(
                    ownReactions.join(' '),
                    style: const TextStyle(fontSize: 18),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final controller = ref.read(
                      chatReactionsProvider(chatId).notifier,
                    );
                    try {
                      if (ownReactions.length == 1) {
                        await controller.removeOwnReaction(
                          message.id,
                          ownReactions.first,
                        );
                      } else {
                        await controller.removeAllOwnReactions(message.id);
                      }
                    } catch (_) {
                      // sheetContext is gone after the pop — report on the screen.
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'chat_view.reaction_remove_failed'.tr(),
                            ),
                          ),
                        );
                      }
                    }
                  },
                ),
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
              // Favorite / unfavorite (#4) — only for real (user) messages. A
              // shot cannot be pinned: a bookmark on something that is about to
              // disappear would be a promise the favorites list cannot keep.
              if (appMessage != null && !isShotMessage(message.message))
                ListTile(
                  leading: Icon(isFavorite ? Icons.star : Icons.star_border),
                  title: Text(
                    (isFavorite ? 'chat_view.unfavorite' : 'chat_view.favorite')
                        .tr(),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    ref
                        .read(messagesControllerProvider(chatId).notifier)
                        .toggleFavorite(appMessage);
                    // Keep the (possibly still-mounted) favorites view in sync
                    // — it's an autoDispose FutureProvider that otherwise shows
                    // a stale snapshot when you pop back to it after toggling.
                    // Invalidate the WHOLE family: two modes hang on it (all
                    // chats and this one only), and refreshing just one of them
                    // leaves the other lying.
                    ref.invalidate(favoriteMessagesProvider);
                    ref.invalidate(chatFavoriteCountProvider(chatId));
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
                  title: Text(editLabelKey.tr()),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onEdit();
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
              // Delete sits right at the bottom because it is the only
              // destructive action in the sheet: a thumb landing on the edge
              // while scrolling must not come down on it. Whoever adds an
              // action here puts it ABOVE.
              if (onDelete != null)
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: Text(
                    'chat_view.delete'.tr(),
                    style: const TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onDelete();
                  },
                ),
            ],
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
