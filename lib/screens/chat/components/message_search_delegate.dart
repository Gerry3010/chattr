// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../features/messages/message_model.dart';
import '../../../features/messages/message_search_text.dart';
import '../../../features/profiles/widgets/user_avatar.dart';

/// Full-text search over a chat's locally-decrypted messages.
///
/// The server only ever holds ciphertext, so the search runs entirely against
/// the local (decrypted-in-memory) message store via [ChatViewController].
class MessageSearchDelegate extends SearchDelegate<void> {
  /// The search itself — as a function, not as a whole controller.
  ///
  /// Only `searchMessages` was needed of it in any case. A `ChatViewController`
  /// hangs on a `Ref` and cannot be built for a test; this class is thereby
  /// testable without half a Riverpod world.
  final Future<List<Message>> Function(String query) search;

  final Map<String, String> usernames;
  final String? currentUserId;

  /// Jump to a hit.
  ///
  /// **Why as a callback and not in here.** The jump is more than a scroll: if
  /// the hit lies outside the loaded window, `highlightMessage` is a SILENT
  /// failure — older history has to be paged in first (`openChatAtMessage`, the
  /// same trap as with an old favorite on 2026-08-23). This class cannot do
  /// that: it has no `WidgetRef` and its own context is dead as soon as [close]
  /// has run. So the caller does it, who still has both.
  final void Function(String messageId) onJump;

  MessageSearchDelegate({
    required this.search,
    required this.usernames,
    required this.currentUserId,
    required this.onJump,
  });

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  @override
  Widget buildResults(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) {
      return Center(child: Text('messages_search.hint'.tr()));
    }
    return FutureBuilder<List<Message>>(
      future: search(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snapshot.data ?? const [];
        if (results.isEmpty) {
          return Center(child: Text('messages_search.no_results'.tr()));
        }
        return ListView.separated(
          itemCount: results.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final msg = results[index];
            final isOwn = msg.senderId == currentUserId;
            final senderName = isOwn
                ? 'chat_detail.you'.tr()
                : (usernames[msg.senderId] ?? 'chat_detail.unknown_user'.tr());
            return ListTile(
              // A hit one cannot tap is a preview of something there is no
              // route to (reported by Gerry, 2026-08-30). Close the search
              // first, then jump — the jump needs the chat underneath, not this
              // page.
              onTap: () {
                close(context, null);
                onJump(msg.id);
              },
              // Shared reactive avatar (real profile photo, initials fallback)
              // instead of an initials-only circle.
              leading: UserAvatar(userId: msg.senderId, radius: 20),
              title: Text(senderName),
              // The same helper that decides on the hit also supplies the row —
              // otherwise a hit without a visible reason would stand here
              // sooner or later (or raw JSON, as it did for media and shots
              // until 2026-09-02).
              subtitle: Text(
                searchableText(msg.decryptedContent) ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                _formatTime(msg.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}. ${two(l.hour)}:${two(l.minute)}';
  }
}
