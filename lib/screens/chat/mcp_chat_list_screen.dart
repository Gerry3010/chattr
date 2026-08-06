// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/chats/chats_controller.dart';
import 'chat_list_screen.dart' show ChatListItem;

/// Lists only the chats an MCP agent has bound to this user (migration
/// 00038_mcp_agent_chats.sql) — reached from the hidden row on the main
/// chat list. Reuses [ChatListItem] so a chat looks/behaves identically
/// whether opened from here or from the main list.
class McpChatListScreen extends ConsumerWidget {
  const McpChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mcpChats =
        ref.watch(chatsControllerProvider).where((c) => c.isMcp).toList();

    return Scaffold(
      appBar: AppBar(title: Text('chat_list.mcp_row.title'.tr())),
      body: mcpChats.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'chat_list.mcp_row.empty'.tr(),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          : ListView.builder(
              itemCount: mcpChats.length,
              itemBuilder: (context, index) =>
                  ChatListItem(chat: mcpChats[index], index: index),
            ),
    );
  }
}
