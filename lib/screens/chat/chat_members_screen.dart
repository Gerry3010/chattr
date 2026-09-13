// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/chats/chat_model.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/identity/identity_verification_controller.dart';
import '../../features/profiles/profile_helpers.dart';
import 'info/widgets/add_member_sheet.dart';
import 'info/widgets/member_tile.dart';

/// The full, searchable member list — the depth behind "show all N".
///
/// The screen no longer builds the rows itself: it shows a search field and a
/// list, the row comes from [MemberTile]. Before, a second member tile, a
/// second action menu and a second invitation sheet lay here — the same jobs as
/// in the info view, only looking different and being differently capable.
class ChatMembersScreen extends ConsumerStatefulWidget {
  final Chat chat;

  const ChatMembersScreen({super.key, required this.chat});

  @override
  ConsumerState<ChatMembersScreen> createState() => _ChatMembersScreenState();
}

class _ChatMembersScreenState extends ConsumerState<ChatMembersScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = ref.watch(authControllerProvider);
    // Watch the LIVING chat, not the snapshot from the constructor: promoting
    // writes `chats.admins`, the `chatUpdate` event triggers `refreshChats`,
    // and only through that does the badge update in place.
    final chats = ref.watch(chatsControllerProvider);
    final chat =
        chats.where((c) => c.id == widget.chat.id).firstOrNull ?? widget.chat;
    final isAdmin = currentUserId != null && chat.isAdmin(currentUserId);
    final membersAsync = ref.watch(chatMembersProvider(widget.chat.id));
    // Trust state per member (audit C1). Deliberately read via `.asData` and
    // without a loading indicator: the provider queries profile and keys per
    // member — a slow connection must not hold up the list, it simply gets its
    // shields a little later.
    final verification =
        ref.watch(chatVerificationProvider(widget.chat.id)).asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: Text('chat_members.title'.tr()),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.person_add),
              onPressed: () => showAddMemberSheet(context: context, chat: chat),
              tooltip: 'chat_members.add_member'.tr(),
            ),
        ],
      ),
      body: membersAsync.when(
        data: (memberIds) {
          if (memberIds.isEmpty) {
            return Center(child: Text('chat_members.empty'.tr()));
          }

          final queryParts = _searchQuery
              .toLowerCase()
              .split(' ')
              .where((part) => part.isNotEmpty)
              .toList();

          final filtered = queryParts.isEmpty
              ? memberIds
              : memberIds.where((memberId) {
                  final username = ref
                      .read(optionalUsernameProvider(memberId))
                      ?.toLowerCase();
                  if (username == null) return false;
                  return queryParts.any(username.contains);
                }).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'chat_members.search_hint'.tr(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? _NoResults()
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final memberId = filtered[index];
                          return MemberTile(
                            chat: chat,
                            memberId: memberId,
                            currentUserId: currentUserId,
                            isCurrentUserAdmin: isAdmin,
                            trust: verification?.peers[memberId],
                            showId: true,
                          );
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('common.error'.tr(args: [err.toString()])),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'chat_members.no_results'.tr(),
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
