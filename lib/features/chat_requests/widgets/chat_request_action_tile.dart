// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../core/navigation/chat_navigation.dart';
import '../../../screens/chat/chat_view_screen.dart';
import '../../../screens/chat/pending_requests_screen.dart';
import '../../profiles/profile_helpers.dart';
import '../chat_request_model.dart';
import '../chat_requests_controller.dart';
import '../chat_requests_repository.dart';

/// The one row by which one gets from a person to a 1:1 chat.
///
/// It stands in a group member's profile sheet and on the person screen — both
/// show the same person, so there must not be two rows with different opinions
/// about what is currently possible.
///
/// What it offers is decided by [chatRequestStatusFor]; what stands here is
/// only how it looks and what the tap sets off.
class ChatRequestActionTile extends ConsumerWidget {
  final String peerId;

  /// Called before navigating — in the sheet, to close it.
  final VoidCallback? onBeforeNavigate;

  const ChatRequestActionTile({
    super.key,
    required this.peerId,
    this.onBeforeNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Agents cannot consent. The MCP server knows only group joins
    // (`chattr_pending`/`chattr_approve`); for chat requests it has no
    // counterpart — a request to it would lie there forever, and the user would
    // permanently see "request sent". So nothing is offered here in the first
    // place.
    //
    // Why not let the agent accept instead (Gerry, 2026-08-25): a 1:1 with an
    // agent hangs on no project, and for non-project-bound sessions there is so
    // far no capability — the chat could therefore do nothing a project chat
    // could not do better. As soon as there is a general session, this is the
    // place.
    if (ref.watch(profileProvider(peerId))?.isAgent ?? false) {
      return const SizedBox.shrink();
    }

    final status = ref.watch(chatRequestStatusProvider(peerId));

    return status.when(
      loading: () => const ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        title: Text(''),
        enabled: false,
      ),
      // Without an answer the row offers "request". Hiding it entirely would be
      // worse: the server rejects a superfluous request anyway, but a missing
      // row looks like a fault in the app.
      error: (_, _) => _tile(context, ref, ChatRequestState.none),
      data: (s) => _tile(context, ref, s.state, chatId: s.chatId),
    );
  }

  Widget _tile(
    BuildContext context,
    WidgetRef ref,
    ChatRequestState state, {
    String? chatId,
  }) {
    switch (state) {
      case ChatRequestState.self:
        return const SizedBox.shrink();

      case ChatRequestState.chatExists:
        return ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text('chat_requests.open_chat'.tr()),
          onTap: chatId == null ? null : () => _openChat(context, chatId),
        );

      case ChatRequestState.incoming:
        return ListTile(
          leading: const Icon(Icons.mark_email_unread_outlined),
          title: Text('chat_requests.answer'.tr()),
          subtitle: Text('chat_requests.wants_to_chat'.tr()),
          onTap: () {
            onBeforeNavigate?.call();
            Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const PendingRequestsScreen(),
              ),
            );
          },
        );

      case ChatRequestState.outgoing:
        return ListTile(
          leading: const Icon(Icons.hourglass_empty),
          title: Text('chat_requests.pending'.tr()),
          trailing: TextButton(
            onPressed: () => _withdraw(context, ref),
            child: Text('chat_requests.withdraw'.tr()),
          ),
        );

      case ChatRequestState.none:
        return ListTile(
          leading: const Icon(Icons.person_add_alt_1_outlined),
          title: Text('chat_requests.send'.tr()),
          onTap: () => _send(context, ref),
        );
    }
  }

  void _openChat(BuildContext context, String chatId) {
    onBeforeNavigate?.call();
    Navigator.push(
      context,
      appPageRoute<void>(
        settings: RouteSettings(name: chatRouteName(chatId)),
        builder: (_) => ChatViewScreen(chatId: chatId),
      ),
    );
  }

  Future<void> _send(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(chatRequestsRepositoryProvider).send(peerId);
      ref.invalidate(outgoingChatRequestsProvider);
      ref.invalidate(chatRequestStatusProvider(peerId));
      messenger.showSnackBar(
        SnackBar(content: Text('chat_requests.sent'.tr())),
      );
    } on ChatRequestException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_reason(e.reason))));
    }
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(chatRequestsRepositoryProvider).withdraw(peerId);
    ref.invalidate(outgoingChatRequestsProvider);
    ref.invalidate(chatRequestStatusProvider(peerId));
    messenger.showSnackBar(
      SnackBar(content: Text('chat_requests.withdrawn'.tr())),
    );
  }

  static String _reason(ChatRequestFailure reason) => switch (reason) {
        ChatRequestFailure.noSuchUser => 'chat_requests.no_such_user'.tr(),
        ChatRequestFailure.chatExists => 'chat_requests.chat_exists'.tr(),
        ChatRequestFailure.tooMany => 'chat_requests.too_many'.tr(),
        ChatRequestFailure.unknown => 'chat_requests.failed'.tr(),
      };
}
