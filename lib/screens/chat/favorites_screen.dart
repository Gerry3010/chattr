// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/app_page_route.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/media/media_attachment.dart';
import '../../features/media/media_preview_label.dart';
import '../../features/messages/message_model.dart';
import '../../features/messages/messages_local_provider.dart';
import 'chat_view_screen.dart';
import 'components/forward_chat_sheet.dart' show forwardChatDisplayName;

/// All favorited messages across chats, newest first (#4). autoDispose so it
/// re-queries each time the screen opens (reflecting toggles made meanwhile).
final favoriteMessagesProvider = FutureProvider.autoDispose<List<Message>>((
  ref,
) async {
  final repo = ref.read(messagesLocalRepositoryProvider);
  return repo.getFavoriteMessages();
});

/// A flat list of the user's favorited messages (#4). Tapping one opens its
/// chat. Local-only — reads the encrypted local store, never the server.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favsAsync = ref.watch(favoriteMessagesProvider);
    final currentUserId = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text('chat_list.favorites'.tr())),
      body: favsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (messages) {
          if (messages.isEmpty) {
            return Center(child: Text('chat_list.favorites_empty'.tr()));
          }
          return ListView.separated(
            itemCount: messages.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final m = messages[i];
              final chat = ref
                  .watch(chatsControllerProvider)
                  .where((c) => c.id == m.chatId)
                  .firstOrNull;
              final chatName = chat == null
                  ? m.chatId.substring(0, 8)
                  : forwardChatDisplayName(ref, chat, currentUserId);
              return ListTile(
                leading: const Icon(Icons.star, color: Colors.amber),
                title: Text(
                  _previewFor(m),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(chatName),
                onTap: chat == null
                    ? null
                    : () => Navigator.push(
                        context,
                        appPageRoute<void>(
                          builder: (_) => ChatViewScreen(
                            chatId: m.chatId,
                            highlightMessageId: m.id,
                          ),
                        ),
                      ),
              );
            },
          );
        },
      ),
    );
  }

  /// Preview text for a favorited message — the decrypted text, or a media
  /// label (with caption if present) for media messages.
  String _previewFor(Message m) {
    final content = m.decryptedContent;
    if (content == null || content.isEmpty) {
      return 'chat_view.encrypted'.tr();
    }
    final album = MediaAlbum.tryParse(content);
    // Was its own copy of the caption-else-"Medien" rule; now the same label
    // as reply quotes, search hits and notifications, so a favorited photo
    // reads the same wherever it shows up.
    if (album != null) return mediaPreviewLabel(album);
    return content;
  }
}
