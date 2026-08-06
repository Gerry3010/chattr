// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chats/widgets/chat_avatar.dart';
import '../../features/media/media_attachment.dart';
import '../../features/media/media_preview_label.dart';
import '../../features/messages/global_search_controller.dart';
import '../../features/profiles/profile_helpers.dart';
import 'chat_view_screen.dart';

/// Global (cross-chat) message search over the locally-decrypted store.
/// A hit opens its chat; content never leaves the device.
class GlobalSearchScreen extends ConsumerStatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  ConsumerState<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends ConsumerState<GlobalSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Full-store decrypt is costly, so wait for a pause in typing.
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'messages_search.global_hint'.tr(),
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _onChanged('');
              },
            ),
        ],
      ),
      body: _query.isEmpty
          ? Center(child: Text('messages_search.global_prompt'.tr()))
          : _Results(query: _query),
    );
  }
}

/// Two optional sections: matching contacts/chats first (instant, by name),
/// then message hits (async, by content). A section with no matches is omitted
/// entirely; only when BOTH are empty do we show the "no results" state.
class _Results extends ConsumerWidget {
  final String query;
  const _Results({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactIds = ref.watch(contactSearchProvider(query));
    final messagesAsync = ref.watch(globalMessageSearchProvider(query));

    final children = <Widget>[];

    if (contactIds.isNotEmpty) {
      children.add(_SectionHeader('messages_search.section_contacts'.tr()));
      children.addAll(contactIds.map((id) => _ContactTile(chatId: id)));
    }

    final messageSection = messagesAsync.when(
      loading: () => const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (e, _) => [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text('messages_search.error'.tr(args: ['$e']))),
        ),
      ],
      data: (hits) {
        if (hits.isEmpty) return const <Widget>[];
        return [
          _SectionHeader('messages_search.section_messages'.tr()),
          for (final hit in hits) _HitTile(hit: hit, query: query),
        ];
      },
    );
    children.addAll(messageSection);

    // "No results" only once messages have settled empty AND no contacts match.
    final messagesEmpty = messagesAsync.maybeWhen(
      data: (h) => h.isEmpty,
      orElse: () => false,
    );
    if (contactIds.isEmpty && messagesEmpty) {
      return Center(child: Text('messages_search.no_results'.tr()));
    }

    return ListView(children: children);
  }
}

/// A bold, primary-tinted section label ("Kontakte" / "Nachrichten").
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// A contact/chat suggestion row — tap opens the chat directly.
class _ContactTile extends ConsumerWidget {
  final String chatId;
  const _ContactTile({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(chatDisplayNameProvider(chatId));
    return ListTile(
      leading: ChatAvatar(chatId: chatId),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.push(
        context,
        appPageRoute<void>(builder: (_) => ChatViewScreen(chatId: chatId)),
      ),
    );
  }
}

class _HitTile extends ConsumerWidget {
  final GlobalSearchHit hit;
  final String query;
  const _HitTile({required this.hit, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUserId = ref.watch(authControllerProvider);
    final chatName = ref.watch(chatDisplayNameProvider(hit.chatId));
    final isOwn = hit.message.senderId == currentUserId;
    final sender = isOwn
        ? 'chat_detail.you'.tr()
        : ref.watch(usernameProvider(hit.message.senderId));

    return ListTile(
      leading: ChatAvatar(chatId: hit.chatId, fallbackInitial: chatName),
      title: Text(chatName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$sender: ${_preview(hit.message.decryptedContent)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatDate(hit.message.createdAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => Navigator.push(
        context,
        appPageRoute<void>(
          builder: (_) => ChatViewScreen(
            chatId: hit.chatId,
            highlightMessageId: hit.message.id,
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.';
  }

  /// Human-readable preview: media messages are a JSON album blob under the
  /// hood — render them as "📷 Foto" / the caption instead of raw JSON.
  String _preview(String? content) {
    if (content == null || content.isEmpty) return '';
    final album = MediaAlbum.tryParse(content);
    return album != null ? mediaPreviewLabel(album) : content;
  }
}
