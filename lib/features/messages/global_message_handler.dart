// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chattr/features/messages/messages_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_bus_service.dart';
import '../../core/events/event_types.dart';
import '../../core/crypto/envelope_version.dart';
import '../../core/crypto/message_context.dart';
import '../../core/logging/logger_service.dart';
import '../../core/models/optional.dart';
import '../../core/notifications/active_chat_provider.dart';
import '../../core/security/chat_key_pair_manager.dart';
import '../../core/security/message_encryption_service.dart';
import '../../core/security/prekey_manager.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chats_controller.dart';
import '../chats/unread_rules.dart';
import '../identity/message_signature_verifier.dart';
import '../summary/summary_envelope.dart';
import 'message_model.dart';
import 'messages_local_provider.dart';
import 'messages_local_repository.dart';
import 'messages_repository.dart';

/// Provider for the global message handler
final globalMessageHandlerProvider = Provider<GlobalMessageHandler>((ref) {
  final repo = MessagesRepository(ref.read(supabaseClientProvider));
  final localRepo = ref.read(messagesLocalRepositoryProvider);
  final keyManager = ref.read(chatKeyPairManagerProvider);
  final messageEncryption = ref.read(messageEncryptionServiceProvider);
  final eventBus = ref.watch(eventBusProvider);
  final userId = ref.watch(authControllerProvider);

  final handler = GlobalMessageHandler(
    ref,
    repo,
    localRepo,
    keyManager,
    messageEncryption,
    eventBus,
    userId,
  );

  ref.onDispose(() => handler.dispose());

  return handler;
});

/// The realtime event a server row would have produced, so a message picked
/// up late goes through exactly the same path as one that arrived live.
///
/// Returns null for a row whose ciphertext is already gone (`mark_message_
/// received` blanks it): there is nothing left to decrypt, and an event for it
/// would be pure noise.
@visibleForTesting
NewMessageEvent? catchUpEventFor(MessageInterface message) {
  final ciphertext = message.encryptedContent;
  if (ciphertext == null || ciphertext.isEmpty) return null;
  final reply = message is Message ? message : null;
  return NewMessageEvent(
    chatId: message.chatId,
    messageId: message.id,
    // A system message has no human sender; handleNewMessage keys off exactly
    // this to decide which kind of message to build.
    senderId: message.isSystemMessage ? null : message.senderId,
    content: ciphertext,
    messageType: message.messageType,
    // This is backlog, not news. Everything else about the replay is meant to
    // be indistinguishable from a live arrival — decryption, prekeys,
    // persistence, receipts — but a banner per caught-up message turns opening
    // the app into a wall of ten notifications (reported 2026-08-19). This is
    // the ONE place catch-up events are built, so the flag set here is the
    // single point where "live" and "backlog" part ways.
    catchUp: true,
    // The SERVER's timestamp, never "now" — a message sorted by arrival time
    // would land at the end of the history instead of where it belongs.
    timestamp: message.createdAt,
    // Without these a caught-up reply loses its quote for good: the server
    // clears the ciphertext the moment the message counts as received.
    replyToMessageId: reply?.replyToMessageId,
    replyToSenderId: reply?.replyToSenderId,
    replyToSenderName: reply?.replyToSenderName,
    replyToPreview: reply?.replyToPreview,
  );
}

/// Global message handler that processes all incoming messages
/// regardless of which chat is currently open
class GlobalMessageHandler {
  final Ref ref;
  final MessagesRepository repo;
  final MessagesLocalRepository localRepo;
  final ChatKeyPairManager keyManager;
  final MessageEncryptionService messageEncryption;
  final EventBusService? eventBus;
  final String? userId;

  StreamSubscription<BusEvent>? _sub;

  GlobalMessageHandler(
    this.ref,
    this.repo,
    this.localRepo,
    this.keyManager,
    this.messageEncryption,
    this.eventBus,
    this.userId,
  ) {
    _init();
  }

  void _init() {
    if (eventBus == null || userId == null) return;

    _sub = eventBus!.eventStream.listen((event) {
      // Decrypt + persist incoming encrypted messages.
      if (event is NewMessageEvent && !event.decrypted) {
        handleNewMessage(event);
      } else if (event is MessageUpdateEvent) {
        // Read receipts.
        _handleMessageUpdate(event);
      } else if (event is MessageDeleteEvent) {
        // Remove deleted messages from local storage (also for closed chats).
        _handleMessageDelete(event);
      }
    });

    logger.info(
      'GlobalMessageHandler initialized for user $userId',
      tag: 'GlobalMessageHandler',
    );
  }

  /// Handle incoming encrypted message: decrypt, save, and re-emit as decrypted
  @visibleForTesting
  Future<void> handleNewMessage(NewMessageEvent event) async {
    if (event.processed) {
      return;
    }
    try {
      if (userId == null) return;

      MessageInterface message;
      if (event.senderId == null || event.messageType == MessageType.system) {
        message = SystemMessage(
          id: event.messageId,
          chatId: event.chatId,
          recipientId: userId!,
          createdAt: event.timestamp,
          encryptedContent: event.content,
        );
      } else {
        message = Message(
          id: event.messageId,
          chatId: event.chatId,
          senderId: event.senderId!,
          recipientId: userId!,
          encryptedContent: event.content,
          createdAt: event.timestamp,
          // Reply metadata rides on the broadcast (00029). Building the
          // message WITHOUT these used to strip every reply down to a plain
          // bubble — and since markAsReceived clears the server ciphertext
          // right after, the quote was gone for good.
          replyToMessageId: event.replyToMessageId,
          replyToSenderId: event.replyToSenderId,
          replyToSenderName: event.replyToSenderName,
          replyToPreview: event.replyToPreview,
        );
      }

      // Get private keys for this chat (current + previous after a rotation).
      final privateKeys = await keyManager.getAllPrivateKeys(event.chatId);
      if (privateKeys.isEmpty) {
        logger.warning(
          'Cannot decrypt message for chat ${event.chatId}: No private key',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      // Decrypt the message
      if (message.encryptedContent == null ||
          message.encryptedContent!.isEmpty) {
        logger.warning(
          'Cannot decrypt message ${message.id}: Empty encrypted content',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      // v4 envelopes are AAD-bound to (chat, sender, message); system
      // messages are authored by the edge function under the 'system' sender.
      final context = MessageContext(
        chatId: event.chatId,
        senderId: message.senderId,
        messageId: message.id,
      );
      final DecryptedEnvelope envelope;
      try {
        envelope = await messageEncryption.decryptEnvelopeTryKeys(
          message.encryptedContent!,
          privateKeys,
          context: context,
          prekeyResolver: _resolvePrekey,
        );
      } on EnvelopeTooNewException catch (e) {
        // The sender runs a newer build than this one. Store a notice so the
        // message at least EXISTS in the chat, at the right time and from the
        // right person — before this, it vanished without a trace, and a gap
        // nobody can see is a gap nobody reports.
        //
        // Deliberately NOT marked as received: the server keeps its copy, so
        // after an update the ordinary catch-up (`received_at IS NULL`) fetches
        // it again and the real content replaces this placeholder. The notice
        // is a stand-in, not a tombstone.
        await _saveToLocal(
          message.withDecryptedContent(
            UnsupportedEnvelopeNotice(e.version).encode(),
          ),
        );
        logger.warning(
          'Message ${message.id} uses envelope v${e.version}, newer than this '
          'build (max ${EnvelopeVersions.maxSupported}) — placeholder stored, '
          'server copy left intact for a retry after updating',
          tag: 'GlobalMessageHandler',
        );
        return;
      }
      final plaintext = envelope.plaintext;

      var decryptedMessage = message.withDecryptedContent(plaintext);
      // Identity-signature check (audit H1, warn-only) — user messages only.
      if (decryptedMessage is Message) {
        final status = await ref.read(messageSignatureVerifierProvider).verify(
              context: context,
              plaintext: plaintext,
              signatureB64: envelope.signatureB64,
              envelopeVersion: envelope.version,
            );
        if (status != null) {
          decryptedMessage = decryptedMessage.copyWith(
            sigStatus: Optional(status),
          );
        }
      }

      // Decrypt the reply-quote preview (per-recipient ciphertext, like
      // content). Strictly best-effort: a preview failure must never drop the
      // message itself — messages sent before the per-recipient preview fix
      // carry a ciphertext only one group member can decrypt.
      String? previewPlaintext;
      final encryptedPreview = event.replyToPreview;
      if (decryptedMessage is Message &&
          encryptedPreview != null &&
          encryptedPreview.isNotEmpty) {
        try {
          previewPlaintext = await messageEncryption.decryptMessageTryKeys(
            encryptedPreview,
            privateKeys,
            context: context,
            prekeyResolver: _resolvePrekey,
          );
          decryptedMessage = decryptedMessage.copyWith(
            decryptedReplyPreview: Optional(previewPlaintext),
          );
        } catch (e) {
          logger.warning(
            'Reply preview of ${message.id} could not be decrypted '
            '(message kept, quote falls back): $e',
            tag: 'GlobalMessageHandler',
          );
        }
      }

      // Save to local storage. markAsReceived clears the server ciphertext —
      // after that the local copy is the ONLY one. If persisting failed, keep
      // the server copy so the message can be re-fetched later instead of
      // being lost on both sides.
      final persist = await _saveToLocal(decryptedMessage);
      if (!persist.saved) {
        logger.warning(
          'Local persist failed for ${message.id} — leaving server copy '
          'intact (no markAsReceived)',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      // Mark as received on server
      final receivedAt = await repo.markAsReceived(
        event.chatId,
        message.id,
        userId!,
      );

      // Mark as received locally
      await localRepo.markAsReceived(
        event.chatId,
        message.id,
        userId!,
        timestamp: receivedAt,
      );

      // Forward secrecy (P3): the message is persisted and the server copy is
      // cleared, so destroy the one-time prekey it consumed (content + preview
      // share it). After this the ciphertext is unwrappable by no one — the
      // forward-secrecy act. Consume-once site; the delete is idempotent.
      if (envelope.prekeyId != null) {
        await ref.read(prekeyManagerProvider).consume(envelope.prekeyId!);
      }

      logger.info(
        '📥 Processed message ${message.id} for chat ${event.chatId}',
        tag: 'GlobalMessageHandler',
      );

      // Update chat metadata (lastMessageAt and unreadCount). Only a genuinely
      // new message bumps the unread badge — a re-delivered one (catch-up) must
      // not phantom-increment it. Summary machinery is not conversation: it
      // must neither raise the unread badge (asking for a summary would mark
      // the chat unread for the person who asked) nor touch lastMessageAt
      // (the chat would jump to the top of the list over a message nobody
      // can see) — so it skips the metadata update entirely.
      if (!isSummaryEnvelope(plaintext)) {
        await _updateChatMetadata(
          event.chatId,
          event.timestamp,
          message.senderId,
          isNew: persist.isNew,
        );
      }

      // Emit the decrypted message event in-process for UI and notifications.
      // Convention: after this re-emit, replyToPreview carries PLAINTEXT, or
      // '' when the preview couldn't be decrypted (copyWith's `??` semantics
      // can't null a field; consumers treat empty as absent).
      eventBus?.emit(
        event
            .copyWith(
              decrypted: true,
              content: plaintext,
              replyToPreview: previewPlaintext ?? '',
            )
            .asProcessed(),
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle new message in global handler',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Save message to local storage. Returns whether the persist SUCCEEDED
  /// ([saved] — callers must not clear the server ciphertext when false, or the
  /// message is lost on both sides) and whether it was GENUINELY NEW ([isNew] —
  /// false when the row already existed, e.g. a #121 catch-up re-delivery). The
  /// caller gates the unread increment on [isNew] so a re-delivered message
  /// doesn't phantom-bump the badge.
  Future<({bool saved, bool isNew})> _saveToLocal(
      MessageInterface message) async {
    try {
      // Check if message already exists
      final exists = await localRepo.hasMessage(message.id);
      await localRepo.saveMessage(message, update: exists);
      return (saved: true, isNew: !exists);
    } catch (e, stackTrace) {
      logger.error(
        'Failed to save message to local storage',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
      return (saved: false, isNew: false);
    }
  }

  /// Update chat metadata (lastMessageAt and unreadCount). [isNew] gates the
  /// unread bump: a re-delivered (already-persisted) message updates ordering
  /// but must not increment the badge.
  ///
  /// Neither does a message arriving in the chat the user is CURRENTLY LOOKING
  /// AT. That used to bump the badge and rely on the open chat racing back to
  /// zero — the same signal that already suppresses this chat's in-app banner
  /// and chime (`activeChatProvider`) answers it without a race.
  Future<void> _updateChatMetadata(
    String chatId,
    DateTime messageTimestamp,
    String? senderId, {
    required bool isNew,
  }) async {
    try {
      final chatsController = ref.read(chatsControllerProvider.notifier);
      await chatsController.updateChatMetadata(
        chatId: chatId,
        lastMessageAt: messageTimestamp,
        incrementUnread: shouldBumpUnread(
          isNew: isNew,
          senderId: senderId,
          currentUserId: userId,
          chatId: chatId,
          activeChatId: ref.read(activeChatProvider),
        ),
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to update chat metadata',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Handle message update event (read receipts)
  /// Recipient side of an edit: re-fetch our ciphertext, decrypt it and replace
  /// the stored plaintext, then re-mark as received/read (which re-clears the
  /// server ciphertext) and emit a processed event so the open chat updates.
  Future<void> _handleMessageEdit(MessageUpdateEvent event) async {
    try {
      final message = await ref
          .read(messagesControllerProvider(event.chatId).notifier)
          .getMessage(event.messageId);
      if (message == null) {
        logger.warning(
          'Cannot apply edit to ${event.messageId}: not found locally',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      final privateKeys = await keyManager.getAllPrivateKeys(event.chatId);
      if (privateKeys.isEmpty) {
        logger.warning(
          'Cannot apply edit for chat ${event.chatId}: no private key',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      final fetched = await repo.fetchEncryptedContent(
        event.chatId,
        event.messageId,
        userId!,
      );
      if (fetched == null) {
        logger.warning(
          'Cannot apply edit to ${event.messageId}: ciphertext unavailable',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      final context = MessageContext(
        chatId: event.chatId,
        senderId: message.senderId,
        messageId: event.messageId,
      );
      final envelope = await messageEncryption.decryptEnvelopeTryKeys(
        fetched.content,
        privateKeys,
        context: context,
        prekeyResolver: _resolvePrekey,
      );
      final plaintext = envelope.plaintext;
      // Persist the edit marker so the recipient's UI shows the "Edited"
      // label too (authoritative edited_at from the row, local time as
      // fallback — content_changed only fires on genuine edits). Edits only
      // exist for user messages, so the decrypted copy is always a Message.
      final decrypted = message.withDecryptedContent(plaintext);
      var edited = decrypted is Message
          ? decrypted.copyWith(
              editedAt: Optional(fetched.editedAt ?? DateTime.timestamp()),
            )
          : decrypted;
      // Re-verify the identity signature over the edited plaintext (audit H1).
      if (edited is Message) {
        final status = await ref.read(messageSignatureVerifierProvider).verify(
              context: context,
              plaintext: plaintext,
              signatureB64: envelope.signatureB64,
              envelopeVersion: envelope.version,
            );
        edited = edited.copyWith(
          sigStatus: Optional(status),
        );
      }
      final persist = await _saveToLocal(edited);
      if (!persist.saved) {
        logger.warning(
          'Local persist of edit ${event.messageId} failed — leaving server '
          'ciphertext intact (no markAsReceived)',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      // Re-clear the server ciphertext now that we've consumed the new content.
      await repo.markAsReceived(event.chatId, event.messageId, userId!);

      // Forward secrecy (P3): an edit re-encrypts to a FRESH prekey; destroy it
      // now that the edited content is persisted + the server copy cleared.
      if (envelope.prekeyId != null) {
        await ref.read(prekeyManagerProvider).consume(envelope.prekeyId!);
      }

      logger.info(
        '✏️ Applied edit to message ${event.messageId}',
        tag: 'GlobalMessageHandler',
      );

      eventBus?.emit(event.asProcessed());
    } catch (e, stackTrace) {
      logger.error(
        'Failed to apply message edit',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Resolver for a v5 envelope to look up the private half of the prekey it
  /// consumed. Never deletes — the delete (forward-secrecy act) is done
  /// explicitly after persist, above.
  Future<String?> _resolvePrekey(String prekeyId) =>
      ref.read(prekeyManagerProvider).privateBlobFor(prekeyId);

  Future<void> _handleMessageUpdate(MessageUpdateEvent event) async {
    if (event.processed) {
      return;
    }

    // Content edit: the sender re-encrypted this message. Re-fetch our row,
    // decrypt the new ciphertext and replace the stored plaintext.
    if (event.updates['content_changed'] == true) {
      await _handleMessageEdit(event);
      return;
    }

    try {
      // Load the message from local storage
      final message = await ref
          .read(messagesControllerProvider(event.chatId).notifier)
          .getMessage(event.messageId);
      if (message == null) {
        logger.warning(
          'Cannot update message ${event.messageId}: Not found in local storage',
          tag: 'GlobalMessageHandler',
        );
        return;
      }

      // Only process regular messages (not system messages)
      // if (message is! Message) {
      //   return;
      // }

      // Parse the updates and create new maps
      Map<String, DateTime?> newReceivedAt = Map<String, DateTime?>.from(
        message.receivedAt,
      );
      Map<String, DateTime?> newReadAt = Map<String, DateTime?>.from(
        message.readAt,
      );

      bool updated = false;

      // Update receivedAt if present
      if (event.updates.containsKey('received_at')) {
        final receivedAtStr = event.updates['received_at'] as String?;
        if (receivedAtStr != null) {
          newReceivedAt[event.recipientId] = DateTime.parse(receivedAtStr);
          updated = true;
        }
      }

      // Update readAt if present
      if (event.updates.containsKey('read_at')) {
        final readAtStr = event.updates['read_at'] as String?;
        if (readAtStr != null) {
          newReadAt[event.recipientId] = DateTime.parse(readAtStr);
          updated = true;
        }
      }

      if (updated) {
        // Create updated message
        final updatedMessage = message.copyWith(
          receivedAt: newReceivedAt,
          readAt: newReadAt,
        );

        // Save to local storage
        await localRepo.saveMessage(updatedMessage, update: true);

        logger.info(
          '✓ Updated message ${message.id} read receipts',
          tag: 'GlobalMessageHandler',
        );

        // Re-emit the event for UI updates.
        eventBus?.emit(event.asProcessed());
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle message update',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Backfill sender-side read receipts missed while THIS client was closed.
  ///
  /// Receipts reach the sender only through the realtime broadcast
  /// (`notify_message_update`); whatever fired while we were offline is gone,
  /// and since 00010 a sender cannot read its own sent rows via a normal query.
  /// On start/resume we pull the delivery/read status of our sent messages via
  /// the SECURITY DEFINER RPC (00042), merge the per-recipient timestamps into
  /// the local copies (advancing only — a timestamp is set once and never
  /// cleared, so we only fill nulls), and nudge any open chat's UI.
  ///
  /// View-independent by design: the source of truth is the local DB, updated
  /// regardless of which screen (if any) is open. The `since` watermark bounds
  /// the query to statuses that changed since the last successful reconcile.
  /// Pick up messages that arrived while this device wasn't listening — in
  /// EVERY chat, not just an open one.
  ///
  /// Realtime only reaches a running app. Everything that lands while it is
  /// closed used to wait on the server until the user opened that particular
  /// chat, because `_fetchMissedMessages` lives in `MessagesController` and
  /// that only exists for the chat on screen. Since the unread count became
  /// local (1.15.0) the badge counts what the device HOLDS — so those messages
  /// could never raise it, and opening the chat moved the read marker past
  /// them in the same breath. Hence: no badge, ever, for anything that arrived
  /// while the app was away.
  ///
  /// Each row is replayed through [handleNewMessage], the same path realtime
  /// takes, so decryption, one-time prekey consumption, persistence, the
  /// metadata bump and `markAsReceived` all behave identically. `isNew` there
  /// keeps a re-delivered message from bumping the badge twice.
  Future<void> catchUpUndelivered() async {
    final currentUserId = userId;
    if (currentUserId == null) return;
    try {
      const limit = 200;
      final pending = await repo.fetchUndelivered(currentUserId, limit: limit);
      if (pending.isEmpty) return;

      logger.info(
        'Catch-up: ${pending.length} undelivered message(s) across all chats',
        tag: 'GlobalMessageHandler',
      );
      if (pending.length == limit) {
        // Never let a bounded pass look like a complete one.
        logger.warning(
          'Catch-up hit the $limit-message cap — more may be waiting; the '
          'next catch-up picks them up.',
          tag: 'GlobalMessageHandler',
        );
      }

      for (final message in pending) {
        final event = catchUpEventFor(message);
        if (event != null) await handleNewMessage(event);
      }
    } catch (e, stackTrace) {
      // Best effort: a failed catch-up must never keep the app from starting.
      logger.error(
        'Failed to catch up undelivered messages',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> reconcileSentReceipts() async {
    if (userId == null || eventBus == null) return;
    try {
      final watermark = await localRepo.getSentReceiptsWatermark();
      final rows = await repo.fetchSentMessageStatus(since: watermark);
      if (rows.isEmpty) return;

      // The watermark must advance past every row we saw — not just the ones
      // that changed something locally — or already-applied rows get refetched
      // forever.
      DateTime? maxSeen = watermark;
      DateTime? later(DateTime? cur, String? iso) {
        if (iso == null) return cur;
        final t = DateTime.parse(iso);
        return (cur == null || t.isAfter(cur)) ? t : cur;
      }

      // Group all recipient rows by message (group chats have one row each).
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        grouped.putIfAbsent('${r['chat_id']}|${r['id']}', () => []).add(r);
        maxSeen = later(maxSeen, r['received_at'] as String?);
        maxSeen = later(maxSeen, r['read_at'] as String?);
      }

      var updatedCount = 0;
      for (final entry in grouped.entries) {
        final sep = entry.key.indexOf('|');
        final chatId = entry.key.substring(0, sep);
        final messageId = entry.key.substring(sep + 1);

        final local = await localRepo.getMessage(chatId, messageId);
        if (local is! Message) continue; // deleted locally, or a system row

        final newReceivedAt = Map<String, DateTime?>.from(local.receivedAt);
        final newReadAt = Map<String, DateTime?>.from(local.readAt);
        var changed = false;
        for (final r in entry.value) {
          final rid = r['recipient_id'] as String;
          final recv = r['received_at'] as String?;
          final read = r['read_at'] as String?;
          if (recv != null && newReceivedAt[rid] == null) {
            newReceivedAt[rid] = DateTime.parse(recv);
            changed = true;
          }
          if (read != null && newReadAt[rid] == null) {
            newReadAt[rid] = DateTime.parse(read);
            changed = true;
          }
        }
        if (!changed) continue;

        await localRepo.saveMessage(
          local.copyWith(receivedAt: newReceivedAt, readAt: newReadAt),
          update: true,
        );
        updatedCount++;

        // Nudge the open chat's UI. _handleMessageUpdate ignores processed
        // events (guard at its top), so this only drives
        // MessagesController._handleMessageUpdateUI, which reloads from local.
        eventBus!.emit(
          MessageUpdateEvent(
            chatId: chatId,
            messageId: messageId,
            recipientId: userId!,
            updates: const {},
            processed: true,
          ),
        );
      }

      final w = maxSeen;
      if (w != null) await localRepo.setSentReceiptsWatermark(w);
      logger.info(
        'Reconciled sent receipts: ${rows.length} row(s), $updatedCount updated',
        tag: 'GlobalMessageHandler',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to reconcile sent receipts',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Remove a deleted message from local storage (covers chats not currently open).
  Future<void> _handleMessageDelete(MessageDeleteEvent event) async {
    try {
      await localRepo.deleteMessage(event.chatId, event.messageId);
      logger.info(
        '🗑️ Deleted message ${event.messageId} from local storage',
        tag: 'GlobalMessageHandler',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to delete message locally',
        tag: 'GlobalMessageHandler',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    logger.info('GlobalMessageHandler disposed', tag: 'GlobalMessageHandler');
  }
}
