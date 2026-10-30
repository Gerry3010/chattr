// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/auth_controller.dart';
import '../../../features/messages/message_reaction_model.dart';
import '../../../features/messages/message_reactions_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../../features/profiles/widgets/user_avatar.dart';

/// Opens the "who reacted" sheet — the app's own, not the package's.
///
/// The one in `chatview` builds from an immutable snapshot and offers no way
/// to act on a row, so a reaction removed while it is open would stay on
/// screen. This one watches `chatReactionsProvider`, so it reflects removals
/// (yours and other people's) as they happen, and lets you take your own
/// reaction back — by swiping the row away or tapping the button on it.
Future<void> showReactionDetailsSheet({
  required BuildContext context,
  required String chatId,
  required String messageId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ReactionDetailsSheet(chatId: chatId, messageId: messageId),
  );
}

/// One line of the sheet: a person and the emoji they picked.
@immutable
class _Row {
  const _Row({required this.userId, required this.emoji});

  final String userId;
  final String emoji;

  /// Stable across rebuilds — a user can appear once per emoji.
  String get key => '$userId|$emoji';
}

List<_Row> _rowsFrom(List<ReactionSummary> summaries) => [
      for (final summary in summaries)
        for (final userId in summary.userIds)
          _Row(userId: userId, emoji: summary.reaction),
    ];

class _ReactionDetailsSheet extends ConsumerStatefulWidget {
  const _ReactionDetailsSheet({required this.chatId, required this.messageId});

  final String chatId;
  final String messageId;

  @override
  ConsumerState<_ReactionDetailsSheet> createState() =>
      _ReactionDetailsSheetState();
}

class _ReactionDetailsSheetState extends ConsumerState<_ReactionDetailsSheet> {
  /// Rows already swiped away. `Dismissible` asserts that a dismissed row is
  /// gone from the list on the very next build; the optimistic state update
  /// usually does that in time, but tying correctness to that timing would be
  /// a bug waiting for a slow frame.
  final _removing = <String>{};

  /// Set once the sheet has asked to close. Since CHAT-63 a removal brings
  /// several state updates in a row (painted gone, reloaded, the realtime
  /// echo). Each rebuilt an empty sheet that asked again, and the second pop
  /// took the chat with it (Gerry's Galaxy, 2026-10-30).
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final summaries =
        ref.watch(chatReactionsProvider(widget.chatId))[widget.messageId] ??
            const <ReactionSummary>[];
    final me = ref.watch(authControllerProvider);
    final rows =
        _rowsFrom(summaries).where((r) => !_removing.contains(r.key)).toList();

    // Nothing left to show — the last reaction was just taken back. Close
    // once, and only our own route while it is still on top: `maybePop`
    // pops whatever is on top, and during the sheet's exit that is the chat.
    if (rows.isEmpty && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isCurrent) Navigator.of(context).pop();
      });
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'chat_view.reactions_title'.tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                final isMine = row.userId == me;
                final tile = _ReactionRowTile(
                  row: row,
                  isMine: isMine,
                  onRemove: isMine ? () => _remove(row) : null,
                );
                // Only your own row is swipeable. Someone else's must look and
                // behave differently, or the gesture is a trap.
                if (!isMine) return tile;
                return Dismissible(
                  key: ValueKey(row.key),
                  direction: DismissDirection.endToStart,
                  background: _removeBackground(context),
                  onDismissed: (_) => _remove(row),
                  child: tile,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _removeBackground(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
  }

  void _remove(_Row row) {
    setState(() => _removing.add(row.key));
    final controller =
        ref.read(chatReactionsProvider(widget.chatId).notifier);
    controller.removeOwnReaction(widget.messageId, row.emoji).catchError((_) {
      // Put it back and say so — a silent failure would look like it worked.
      if (!mounted) return;
      setState(() => _removing.remove(row.key));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('chat_view.reaction_remove_failed'.tr())),
      );
    });
  }
}

class _ReactionRowTile extends ConsumerWidget {
  const _ReactionRowTile({
    required this.row,
    required this.isMine,
    this.onRemove,
  });

  final _Row row;
  final bool isMine;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(row.userId));
    final name = isMine
        ? 'chat_view.reaction_you'.tr()
        : (profile?.username ?? '…');

    return ListTile(
      key: ValueKey('reaction_row_${row.key}'),
      leading: UserAvatar(userId: row.userId, radius: 20),
      title: Text(name),
      subtitle: isMine ? Text('chat_view.reaction_remove_hint'.tr()) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(row.emoji, style: const TextStyle(fontSize: 22)),
          // The swipe is invisible; this button is what makes the action
          // findable at all — which was the whole complaint.
          if (onRemove != null)
            IconButton(
              key: ValueKey('reaction_remove_${row.key}'),
              icon: const Icon(Icons.close),
              tooltip: 'chat_view.reaction_remove_mine'.tr(),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
