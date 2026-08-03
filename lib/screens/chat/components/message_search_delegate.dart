// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../features/chat_view/chat_view_controller.dart';
import '../../../features/messages/message_model.dart';
import '../../../features/profiles/widgets/user_avatar.dart';

/// Full-text search over a chat's locally-decrypted messages.
///
/// The server only ever holds ciphertext, so the search runs entirely against
/// the local (decrypted-in-memory) message store via [ChatViewController].
class MessageSearchDelegate extends SearchDelegate<void> {
  final ChatViewController controller;
  final Map<String, String> usernames;
  final String? currentUserId;

  MessageSearchDelegate({
    required this.controller,
    required this.usernames,
    required this.currentUserId,
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
      future: controller.searchMessages(query),
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
              // Shared reactive avatar (real profile photo, initials fallback)
              // instead of an initials-only circle.
              leading: UserAvatar(userId: msg.senderId, radius: 20),
              title: Text(senderName),
              subtitle: Text(
                msg.decryptedContent ?? '',
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
