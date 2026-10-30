// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/logger_service.dart';
import '../auth/auth_controller.dart';
import '../chats/chats_controller.dart';
import '../messages/message_model.dart';
import '../messages/messages_controller.dart';
import '../messages/messages_local_provider.dart';
import 'call_log.dart';

/// Puts a finished call into its chat — on this device only.
abstract class CallLogWriter {
  Future<void> write({
    required String chatId,
    required CallLogEntry entry,
    required DateTime at,
  });
}

class _LocalCallLogWriter implements CallLogWriter {
  _LocalCallLogWriter(this._ref);
  final Ref _ref;

  @override
  Future<void> write({
    required String chatId,
    required CallLogEntry entry,
    required DateTime at,
  }) async {
    final me = _ref.read(authControllerProvider);
    if (me == null) return;
    final message = SystemMessage(
      // A fresh id: local rows are replace-on-conflict, so it must never be
      // one a server message could carry.
      id: const Uuid().v4(),
      chatId: chatId,
      recipientId: me,
      createdAt: at.toUtc(),
      action: entry.action,
      detail: entry.detail,
    );
    try {
      // The chat open right now: through its controller, so the line shows
      // at once. Otherwise straight into the local DB — it appears the next
      // time the chat loads.
      final provider = messagesControllerProvider(chatId);
      if (_ref.exists(provider)) {
        await _ref.read(provider.notifier).addMessage(message);
      } else {
        await _ref.read(messagesLocalRepositoryProvider).saveMessage(message);
      }
      // Like any message: the chat moves up; only a missed call counts as
      // unread (see isIncomingMessage).
      await _ref.read(chatsControllerProvider.notifier).updateChatMetadata(
            chatId: chatId,
            lastMessageAt: at,
            incrementUnread: entry.action == callMissed,
            bumpToTop: true,
          );
    } catch (e) {
      logger.warning('Call log entry not written: $e', tag: 'Calls');
    }
  }
}

final callLogWriterProvider =
    Provider<CallLogWriter>((ref) => _LocalCallLogWriter(ref));
