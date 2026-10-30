// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/navigation/chat_navigation.dart';
import '../../../core/utils/app_time.dart';
import '../../../features/media/media_attachment.dart';
import '../../../features/messages/message_model.dart';
import '../../../features/messages/messages_local_provider.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../../core/network/load_error_view.dart';

/// Result of an index run: the hits and whether the whole chat was looked at in
/// the process.
typedef ChatMediaIndex = ({List<Message> matches, bool complete});

/// How many messages are touched for the index. Every one of them is decrypted
/// — the same arithmetic as for the in-chat search.
const int kMediaScanLimit = 1000;

final chatMediaIndexProvider =
    FutureProvider.autoDispose.family<ChatMediaIndex, String>((
  ref,
  chatId,
) async {
  final repo = ref.read(messagesLocalRepositoryProvider);
  return repo.getMediaMessages(chatId, scanLimit: kMediaScanLimit);
});

/// "Media & files" — a DIRECTORY, not a gallery.
///
/// The difference is not a convenience but a fact about this app: there is no
/// permanent local copy of media. Every viewing loads the encrypted blob from
/// the server again, and the server deletes it 24 h after all recipients have
/// loaded it (00056), at the latest after three months (00018). A tile gallery
/// would therefore mostly promise pictures that no longer exist.
///
/// The directory instead says WHAT was shared, when and by whom, and jumps into
/// the history. What is presumably gone it says so — it is not checked: that
/// would be one server request per row and would incidentally touch the
/// "downloaded" bookkeeping from 00056.
class ChatMediaScreen extends ConsumerWidget {
  final String chatId;

  const ChatMediaScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexAsync = ref.watch(chatMediaIndexProvider(chatId));

    return Scaffold(
      appBar: AppBar(title: Text('chat_detail.media_and_files'.tr())),
      body: indexAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadErrorView(
          error: e,
          onRetry: () => ref.invalidate(chatMediaIndexProvider(chatId)),
        ),
        data: (index) {
          if (index.matches.isEmpty) {
            return Center(child: Text('chat_detail.media_empty'.tr()));
          }
          return ListView.separated(
            itemCount: index.matches.length + (index.complete ? 0 : 1),
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              // No silent truncation: if the whole chat was not looked at, that
              // stands at the end of the list. Otherwise an incomplete list
              // would read as a complete one.
              if (i == index.matches.length) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'chat_detail.media_scan_limited'
                        .tr(args: ['$kMediaScanLimit']),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return _MediaRow(message: index.matches[i], chatId: chatId);
            },
          );
        },
      ),
    );
  }
}

class _MediaRow extends ConsumerWidget {
  final Message message;
  final String chatId;

  const _MediaRow({required this.message, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = MediaAlbum.tryParse(message.decryptedContent);
    if (album == null) return const SizedBox.shrink();

    final first = album.first;
    final sender = ref.watch(optionalUsernameProvider(message.senderId));
    final locale = Localizations.localeOf(context).toString();

    // Server retention ends after three months — everything older is certainly
    // gone, anything younger only probably still there. So what is presumed is
    // only what can be a presumption anyway.
    final vermutlichFort = DateTime.now().difference(message.createdAt).inDays > 90;

    final titel = album.isAlbum
        ? '${first.name} ${'chat_detail.media_more_items'.tr(args: ['${album.items.length - 1}'])}'
        : first.name;

    return Opacity(
      opacity: vermutlichFort ? 0.55 : 1,
      child: ListTile(
        leading: Icon(_symbolFuer(first.mediaType)),
        title: Text(titel, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            _size(album),
            AppTime.ymdHm(message.createdAt, locale),
            if (sender != null) 'chat_detail.media_from'.tr(args: [sender]),
            if (vermutlichFort) 'chat_detail.media_maybe_expired'.tr(),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => openChatAtMessage(
          context,
          ref,
          chatId: chatId,
          messageId: message.id,
        ),
      ),
    );
  }

  IconData _symbolFuer(MediaType kind) => switch (kind) {
        MediaType.image => Icons.photo_outlined,
        MediaType.video => Icons.videocam_outlined,
        MediaType.audio => Icons.audiotrack_outlined,
        MediaType.file => Icons.insert_drive_file_outlined,
      };

  String _size(MediaAlbum album) {
    final bytes = album.items.fold<int>(0, (sum, it) => sum + it.size);
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
