// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../media/file_chunker.dart';
import '../media/image_metadata.dart';
import '../media/media_attachment.dart';
import '../media/media_compression.dart';
import '../media/video_metadata.dart';
import '../media/video_thumbnail.dart';
import '../media/media_repository.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_bus_service.dart';
import '../../core/events/event_types.dart';
import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import '../../core/crypto/message_context.dart';
import '../../core/models/optional.dart';
import '../../core/security/biometric_auth_service.dart';
import '../../core/security/chat_key_pair_manager.dart';
import '../../core/security/key_locked_exception.dart';
import '../../core/security/keys_not_ready_exception.dart';
import '../../core/security/message_encryption_service.dart';
import '../../core/security/prekey_manager.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chat_member_keys_repository.dart';
import '../chats/chats_controller.dart';
import '../identity/message_signature_verifier.dart';
import '../profiles/profile_helpers.dart';
import '../read_receipts/read_receipts_controller.dart';
import 'message_ordering.dart';
import 'message_model.dart';
import 'messages_local_provider.dart';
import 'messages_local_repository.dart';
import 'messages_repository.dart';

// Source - https://stackoverflow.com/a/73209841
// Posted by Wiktor
// Retrieved 2026-02-17, License - CC BY-SA 4.0

typedef MapList = List<Map<String, dynamic>>;

final messagesControllerProvider = StateNotifierProvider.autoDispose
    .family<MessagesController, List<MessageInterface>, String>((ref, chatId) {
      final repo = MessagesRepository(ref.read(supabaseClientProvider));
      final memberKeysRepo = ref.read(chatMemberKeysRepositoryProvider);
      final localRepo = ref.read(messagesLocalRepositoryProvider);
      final biometricAuth = ref.read(biometricAuthServiceProvider);
      final keyManager = ref.read(chatKeyPairManagerProvider);
      final messageEncryption = ref.read(messageEncryptionServiceProvider);
      final eventBus = ref.watch(eventBusProvider);
      final userId = ref.watch(authControllerProvider);
      return MessagesController(
        ref,
        repo,
        memberKeysRepo,
        localRepo,
        biometricAuth,
        keyManager,
        messageEncryption,
        eventBus,
        userId,
        chatId,
      );
    });

class MessagesController extends StateNotifier<List<MessageInterface>> {
  final Ref ref;
  final MessagesRepository repo;
  final ChatMemberKeysRepository memberKeysRepo;
  final MessagesLocalRepository localRepo;
  final BiometricAuthService biometricAuth;
  final ChatKeyPairManager keyManager;
  final MessageEncryptionService messageEncryption;
  final EventBusService? eventBus;
  final String? userId;
  final String chatId;

  StreamSubscription<BusEvent>? _eventSub;
  StreamSubscription<void>? _resumeSub;
  StreamSubscription<void>? _resubscribedSub;

  /// Guards against overlapping resyncs when the app rapidly pauses/resumes.
  bool _resyncing = false;
  bool _resyncQueued = false;

  /// Periodically removes self-destruct messages whose TTL passed while the chat
  /// is open (incl. the sender's own copy, which isn't covered by the
  /// messageDelete broadcast).
  Timer? _expiryTimer;

  // Pagination state
  bool _hasMore = true;
  bool _isLoadingMore = false;
  static const int _pageSize = 50;

  bool get hasMore => _hasMore;

  bool get isLoadingMore => _isLoadingMore;

  MessagesController(
    this.ref,
    this.repo,
    this.memberKeysRepo,
    this.localRepo,
    this.biometricAuth,
    this.keyManager,
    this.messageEncryption,
    this.eventBus,
    this.userId,
    this.chatId,
  ) : super([]) {
    if (eventBus != null) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      // Attempt biometric authentication
      final authenticated = await biometricAuth.authenticate(
        localizedReason: 'Authenticate to load your messages',
      );

      if (!authenticated) {
        // Authentication failed - don't load data
        return;
      }

      // 0. Sweep any self-destruct messages that expired while away.
      await _sweepExpiredMessages();
      _startExpiryTimer();

      // Subscribe to decrypted-message + read-receipt events FIRST — before the
      // catch-up reads below. GlobalMessageHandler decrypts and persists each
      // message to local storage *before* re-emitting it here, so attaching the
      // listener first closes the gap where a message that landed between the
      // initial DB read and the listener attach was saved locally but never
      // rendered until the chat was reopened (#121 H2). The id-dedup in
      // _handleDecryptedMessage keeps any overlap with the reload harmless.
      _eventSub = eventBus!.eventStream.listen((event) {
        if (event is NewMessageEvent &&
            event.chatId == chatId &&
            event.decrypted) {
          _handleDecryptedMessage(event);
        } else if (event is MessageUpdateEvent && event.chatId == chatId) {
          _handleMessageUpdateUI(event);
        } else if (event is MessageDeleteEvent && event.chatId == chatId) {
          _handleMessageDeletedUI(event);
        }
      });

      // 1. Fetch any missed messages from the server (arrived while offline).
      if (userId != null) {
        await _fetchMissedMessages(userId!);
      }

      // 2. Load initial page from local storage — includes newly fetched rows
      // plus anything the listener above already persisted + appended.
      await _reloadFromLocal(limit: _pageSize);

      // Reset unread count for this chat (user is viewing it)
      final chatsController = ref.read(chatsControllerProvider.notifier);
      await chatsController.resetUnreadCount(chatId);

      // On resume from background: re-fetch messages that arrived while away and
      // reflect them in the open chat (the realtime broadcast was missed).
      _resumeSub = ref
          .read(appLifecycleServiceProvider)
          .onResume
          .listen((_) => resync());

      // Same catch-up when the realtime channel drops and re-subscribes IN PLACE
      // without an app-resume (#121 H1) — the bus fires onResubscribed after the
      // re-join, so backfill whatever broadcast we missed during the dead window.
      _resubscribedSub = eventBus!.onResubscribed.listen((_) => resync());
    } catch (e, stackTrace) {
      logger.error(
        'Failed to initialize messages controller',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      state = [];
      _hasMore = false;
    }
  }

  /// Load a page of messages from local storage into [state], decrypting any
  /// legacy rows still lacking `decryptedContent`. Shared by [_init] (initial
  /// open) and [resync] (resume from background).
  Future<void> _reloadFromLocal({required int limit}) async {
    final messages = await localRepo.loadMessages(chatId, limit: limit);
    final allMessages = await localRepo.getMessageCount(chatId);

    // Decrypt any messages that don't have decryptedContent yet (backward compatibility)
    final decryptedMessages = <MessageInterface>[];
    for (final msg in messages) {
      if (msg.decryptedContent == null || msg.decryptedContent!.isEmpty) {
        // Try to decrypt (current + previous key after a rotation)
        final privateKeys = await keyManager.getAllPrivateKeys(chatId);
        if (privateKeys.isNotEmpty && msg.encryptedContent != null) {
          try {
            final envContext = MessageContext(
              chatId: chatId,
              senderId: msg.senderId,
              messageId: msg.id,
            );
            // A v5 (forward-secret) row is normally decrypted + persisted at
            // receive time, so it reaches here only if that never happened; we
            // pass the resolver so it CAN decrypt, but must NOT consume the
            // prekey here — this is a re-decrypt of stored rows, not a
            // consume-once site.
            final envelope = await messageEncryption.decryptEnvelopeTryKeys(
              msg.encryptedContent!,
              privateKeys,
              context: envContext,
              prekeyResolver: _resolvePrekey,
            );
            final plaintext = envelope.plaintext;
            final decrypted = await _stampSigStatus(
              msg.withDecryptedContent(plaintext),
              envContext,
              plaintext,
              envelope,
            );
            // Re-save with decrypted content
            await _saveToLocal(decrypted);
            decryptedMessages.add(decrypted);
            logger.info(
              '🔓 Decrypted legacy message: ${msg.id}',
              tag: 'MessagesController',
            );
          } catch (e) {
            logger.warning(
              'Failed to decrypt legacy message ${msg.id}: $e',
              tag: 'MessagesController',
            );
            decryptedMessages.add(msg); // Keep as-is if decryption fails
          }
        } else {
          decryptedMessages.add(msg);
        }
      } else {
        decryptedMessages.add(msg);
      }
    }

    state = decryptedMessages;

    // Check if there are more messages
    _hasMore = allMessages > messages.length;
  }

  /// Catch up an already-open chat after the app returns from the background.
  ///
  /// The realtime broadcast for messages that arrived while backgrounded was
  /// missed, so pull them from the server ([_fetchMissedMessages]), sweep any
  /// TTL-expired messages, and reload the visible window — keeping at least the
  /// currently-loaded depth so scrolled-in history isn't collapsed.
  Future<void> resync() async {
    if (userId == null) return;
    // Coalesce: if a resync is already running, queue exactly one re-run rather
    // than dropping this request. Under a rapid reconnect flap the newest missed
    // window must still be backfilled, or the #121 staleness re-appears.
    if (_resyncing) {
      _resyncQueued = true;
      return;
    }
    _resyncing = true;
    try {
      do {
        _resyncQueued = false;
        await _sweepExpiredMessages();
        await _fetchMissedMessages(userId!);
        await _reloadFromLocal(limit: max(_pageSize, state.length));
        // The chat is on screen, so clear its unread badge again.
        await ref
            .read(chatsControllerProvider.notifier)
            .resetUnreadCount(chatId);
      } while (_resyncQueued);
    } catch (e, stackTrace) {
      logger.error(
        'Failed to resync messages on resume',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _resyncing = false;
    }
  }

  /// Add a new message to the state (mostly system messages)
  Future<void> addMessage(MessageInterface message) async {
    try {
      await _saveToLocal(message);
      state = [...state, message];
    } catch (e, stackTrace) {
      logger.error(
        'Failed to add message',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Sign [plaintext] bound to [context] with this device's identity key
  /// (audit H1). Best-effort: signing failure never blocks sending (warn-only
  /// model) — recipients just see the message as unsigned.
  Future<String?> _signMessage(MessageContext context, String plaintext) async {
    try {
      final idm = ref.read(identityKeyManagerProvider);
      return await idm.sign(context.signingBytes(plaintext));
    } catch (e) {
      logger.warning(
        'Could not sign message ${context.messageId}: $e',
        tag: 'MessagesController',
      );
      return null;
    }
  }

  /// Claim one one-time prekey per recipient for a forward-secret (v5) send.
  /// Best-effort per recipient: a recipient we can't claim a prekey for (older
  /// client, exhausted pool, transient error) simply gets a v4 envelope. The
  /// same claimed map is reused for a message's content AND its reply-preview so
  /// one send consumes at most one prekey per recipient.
  Future<Map<String, RecipientPrekey>> _claimPrekeys(
    String chatId,
    Iterable<String> recipientIds,
  ) async {
    final manager = ref.read(prekeyManagerProvider);
    final out = <String, RecipientPrekey>{};
    for (final id in recipientIds) {
      try {
        final claimed =
            await manager.claimForRecipient(chatId: chatId, recipientId: id);
        if (claimed != null) {
          out[id] = (prekeyId: claimed.prekeyId, publicBlob: claimed.publicBlob);
        }
      } catch (e) {
        logger.warning(
          'Prekey claim failed for $id in $chatId; sending v4 to them: $e',
          tag: 'MessagesController',
        );
      }
    }
    return out;
  }

  /// Resolver handed to the decrypt paths so a v5 envelope can look up the
  /// private half of the prekey it consumed. Never deletes — consumption
  /// (the forward-secrecy act) happens separately, only at consume-once sites.
  Future<String?> _resolvePrekey(String prekeyId) =>
      ref.read(prekeyManagerProvider).privateBlobFor(prekeyId);

  /// Verify a decrypted [envelope]'s identity signature and stamp the result
  /// onto [message] (user messages only — system messages are server-authored
  /// and never user-signed).
  Future<MessageInterface> _stampSigStatus(
    MessageInterface message,
    MessageContext context,
    String plaintext,
    DecryptedEnvelope envelope,
  ) async {
    if (message is! Message) return message;
    final status = await ref.read(messageSignatureVerifierProvider).verify(
          context: context,
          plaintext: plaintext,
          signatureB64: envelope.signatureB64,
        );
    if (status == null) return message;
    return message.copyWith(sigStatus: Optional(status));
  }

  /// Fetch the recipient public keys for [chatId] (excluding [senderId]), with a
  /// short bounded retry.
  ///
  /// A member's per-chat key is written by their OWN client a moment after they
  /// join — so right after a QR-add the peer's key can be briefly missing, and a
  /// single fetch returns an empty map → the old code hard-threw and the user
  /// had to reload the app to send (#116). Polling a few times lets that first
  /// message go through once the peer registers (typically well under a second).
  /// If no recipient key appears within the window, throw a typed
  /// [KeysNotReadyException] so the UI can keep the draft and show a "try again"
  /// hint rather than a generic failure.
  Future<Map<String, String>> _fetchRecipientKeys(
    String chatId,
    String senderId,
  ) async {
    const attempts = 4;
    const gap = Duration(milliseconds: 500);
    for (var i = 0; i < attempts; i++) {
      final memberKeys = await memberKeysRepo.getAllPublicKeys(chatId);
      memberKeys.remove(senderId); // never encrypt to ourselves
      if (memberKeys.isNotEmpty) return memberKeys;
      if (i < attempts - 1) await Future<void>.delayed(gap);
    }
    throw const KeysNotReadyException();
  }

  Future<Message> sendMessage(
    String content, {
    String? replyToMessageId,
  }) async {
    if (userId == null) {
      throw Exception('Cannot send message: User not authenticated');
    }

    final senderId = userId!;

    // Sanitize replyToMessageId - treat empty string as null
    if (replyToMessageId != null && replyToMessageId.isEmpty) {
      replyToMessageId = null;
    }

    final createdAt = DateTime.timestamp();

    // The message id is minted client-side so the envelope can be bound to it
    // (AAD) and the identity signature can cover it (audit M3 + H1).
    final messageId = const Uuid().v4();
    final context = MessageContext(
      chatId: chatId,
      senderId: senderId,
      messageId: messageId,
    );

    try {
      // 1. Get all member public keys for this chat (with a short retry: a
      // freshly QR-added peer registers its key a beat after joining — #116).
      final memberKeys = await _fetchRecipientKeys(chatId, senderId);

      // 1b. Forward secrecy (P3): claim one one-time prekey per recipient. Reused
      // for the content AND the reply preview below, so one send burns at most
      // one prekey per recipient; recipients we can't claim for get v4.
      final prekeys = await _claimPrekeys(chatId, memberKeys.keys);

      // 2. Prepare reply data if replying to a message
      String? replyToSenderId;
      String? replyToSenderName;
      String? plaintextReplyPreview;
      Map<String, String>? encryptedReplyPreviews;

      if (replyToMessageId != null && replyToMessageId.isNotEmpty) {
        // Find the original message in state, falling back to the local DB
        // (the original may be older than the loaded page — dropping the
        // reply linkage over that made the quote silently disappear).
        final originalMessage =
            state.where((msg) => msg.id == replyToMessageId).firstOrNull ??
                await localRepo.getMessage(chatId, replyToMessageId);

        if (originalMessage == null) {
          logger.warning(
            'Reply target message $replyToMessageId not found in state or local DB, sending without reply',
            tag: 'MessagesController',
          );
          // Clear reply ID to send as normal message
          replyToMessageId = null;
        } else {
          // Get sender ID and name
          replyToSenderId = originalMessage.senderId;
          final senderProfile = ref.read(profileProvider(replyToSenderId));
          replyToSenderName = senderProfile?.username ?? replyToSenderId;

          // Create preview (first 100 chars of decrypted content). Media
          // messages carry their MediaAttachment JSON descriptor as content —
          // use a readable label instead of leaking the raw JSON.
          final originalContent = originalMessage.decryptedContent;
          final originalAlbum = originalContent != null
              ? MediaAlbum.tryParse(originalContent)
              : null;
          final previewSource =
              originalAlbum != null ? originalAlbum.previewLabel : originalContent;
          plaintextReplyPreview = previewSource != null
              ? (previewSource.length > 100
                    ? '${previewSource.substring(0, 100)}...'
                    : previewSource)
              : '';

          // Encrypt preview for all members — each recipient row must carry
          // the ciphertext for ITS recipient's key. (This used to collapse to
          // `.values.first`, so in groups only one member could ever decrypt
          // the quote.)
          encryptedReplyPreviews = await messageEncryption.encryptForAllMembers(
            plaintextReplyPreview,
            memberKeys,
            context: context,
            recipientPrekeys: prekeys,
          );
        }
      }

      // 3. Encrypt message content for all members (context-bound v4 envelope
      // carrying the identity signature — audit H1/M3).
      final encryptedForRecipients = await messageEncryption
          .encryptForAllMembers(
        content,
        memberKeys,
        context: context,
        signatureB64: await _signMessage(context, content),
        recipientPrekeys: prekeys,
      );

      // 3b. Disappearing messages: if this chat has a TTL, stamp expires_at.
      final ttl = ref.read(chatProvider(chatId))?.messageTtlSeconds;
      final expiresAt = (ttl != null && ttl > 0)
          ? createdAt.add(Duration(seconds: ttl))
          : null;
      if (expiresAt != null) {
        logger.info(
          '⏳ Sending self-destruct message (ttl ${ttl}s, expires $expiresAt)',
          tag: 'MessagesController',
        );
      }

      // 4. Send to server (creates N rows)
      await repo.sendEncryptedMessage(
        chatId: chatId,
        senderId: senderId,
        createdAt: createdAt,
        encryptedForRecipients: encryptedForRecipients,
        replyToMessageId: replyToMessageId,
        replyToSenderId: replyToSenderId,
        replyToSenderName: replyToSenderName,
        replyToPreviews: encryptedReplyPreviews,
        expiresAt: expiresAt,
        messageId: messageId,
      );

      // Initialize received and readAt maps with all recipients
      final receivedAt = {for (var key in memberKeys.keys) key: null};
      final readAt = {for (var key in memberKeys.keys) key: null};

      final newMessage = Message(
        id: messageId,
        chatId: chatId,
        createdAt: createdAt,
        senderId: senderId,
        recipientId: senderId,
        decryptedContent: content,
        receivedAt: receivedAt,
        readAt: readAt,
        replyToMessageId: replyToMessageId,
        replyToSenderId: replyToSenderId,
        replyToSenderName: replyToSenderName,
        // The sender's own row keeps the plaintext preview (computed above,
        // incl. the media label) — no need to store ciphertext locally.
        decryptedReplyPreview: plaintextReplyPreview,
        expiresAt: expiresAt,
      );
      await _saveToLocal(newMessage);

      // Message will arrive via NewMessageEvent and be decrypted
      state = [...state, newMessage];

      // The sender gets NO NewMessageEvent for their own message (no recipient
      // row is created for the sender — see `memberKeys.remove(senderId)`
      // above), so the GlobalMessageHandler never bumps this chat. Without this,
      // the ChatList preview/time/order stays stale after sending — the sender's
      // own chat keeps showing the previous message's day (e.g. "Gestern").
      // Bump the chat metadata here so the sender's list reflects the send
      // immediately (incrementUnread stays false — it's the sender's own message).
      await ref
          .read(chatsControllerProvider.notifier)
          .updateChatMetadata(
            chatId: chatId,
            lastMessageAt: createdAt,
            bumpToTop: true,
          );

      return newMessage;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to send message',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Load more older messages (pagination)
  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore || state.isEmpty) {
      return;
    }

    _isLoadingMore = true;

    try {
      // Find the oldest loaded message by the SAME composite key the DB pages
      // on — (created_at, id), not created_at alone. Using this exact minimum as
      // the keyset boundary guarantees the next page starts strictly below
      // everything already loaded, so messages that share a created_at aren't
      // skipped or duplicated across the page boundary.
      final oldestMessage = state.fold<MessageInterface?>(
        null,
        (prev, current) {
          if (prev == null) return current;
          return isOlderMessage(
                current.createdAt,
                current.id,
                prev.createdAt,
                prev.id,
              )
              ? current
              : prev;
        },
      );
      final beforeDate = oldestMessage?.createdAt;
      final beforeId = oldestMessage?.id;

      // Load next page
      final olderMessages = await localRepo.loadMessages(
        chatId,
        limit: _pageSize,
        beforeDate: beforeDate,
        beforeId: beforeId,
      );

      if (olderMessages.isEmpty) {
        _hasMore = false;
      } else {
        // Prepend older messages to state
        state = [...olderMessages, ...state];
        final allMessages = await localRepo.getMessageCount(chatId);
        _hasMore = allMessages > state.length;
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to load more messages',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      _hasMore = false;
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Delete a message
  /// Send an end-to-end encrypted media attachment (photo/video/audio/file).
  ///
  /// The file bytes are AES-encrypted client-side; only the ciphertext is
  /// uploaded to the private `media` bucket. The media key + metadata travel in
  /// the per-recipient message envelope (wrapped with each member's hybrid key)
  /// exactly like a text message, so the server never sees plaintext or a key.
  /// Send an end-to-end encrypted media album — one or more attachments
  /// (photo/video/audio/file) that share an optional [caption] (#109/#110).
  ///
  /// Each file gets a fresh AES media key; only the ciphertext is uploaded to
  /// the private `media` bucket. ALL items travel in ONE per-recipient message
  /// envelope (a [MediaAlbum]) — the server never sees plaintext or a key. On
  /// any failure every already-uploaded blob is deleted (transactional).
  Future<void> sendMediaAlbum({
    required List<OutgoingMedia> files,
    String? caption,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (files.isEmpty) return;
    if (userId == null) {
      throw Exception('Cannot send media: User not authenticated');
    }
    final senderId = userId!;
    final messageId = const Uuid().v4();
    final createdAt = DateTime.timestamp();
    final context = MessageContext(
      chatId: chatId,
      senderId: senderId,
      messageId: messageId,
    );
    final mediaRepo = ref.read(mediaRepositoryProvider);
    final uploadedPaths = <String>[];

    // Determinate upload progress across all files' chunks (a large chunked
    // video dominates the wall-clock; non-chunked items count as one unit).
    bool isChunked(OutgoingMedia f) =>
        f.sourcePath != null && f.size > MediaRepository.chunkThresholdBytes;
    final totalUnits = files.fold<int>(
      0,
      (s, f) => s +
          (isChunked(f)
              ? (f.size / MediaRepository.chunkSizeBytes).ceil()
              : 1),
    );
    var doneUnits = 0;
    void bumpProgress() {
      doneUnits++;
      onProgress?.call(
          totalUnits == 0 ? 1.0 : (doneUnits / totalUnits).clamp(0.0, 1.0));
    }

    void throwIfCancelled() {
      if (isCancelled?.call() ?? false) {
        throw const MediaSendCancelledException();
      }
    }

    try {
      // Short retry so media sent right after a QR-add doesn't hard-fail while
      // the peer is still registering its chat key (#116).
      final memberKeys = await _fetchRecipientKeys(chatId, senderId);

      // Encrypt + upload each file sequentially (only one plaintext+ciphertext
      // resident in RAM at a time — chunked video streams), collecting the
      // per-item descriptors for the album envelope.
      final attachments = <MediaAttachment>[];
      for (final (index, f) in files.indexed) {
        throwIfCancelled();
        if (f.size > MediaRepository.maxUploadBytes) {
          throw Exception(
            'File too large: ${f.size} bytes '
            '(max ${MediaRepository.maxUploadBytes})',
          );
        }
        // Large files streamed from a path are CHUNKED (never fully in RAM);
        // everything else takes the single-object bytes path.
        if (isChunked(f)) {
          attachments.add(await _uploadChunkedMedia(mediaRepo, chatId,
              messageId, index, f, uploadedPaths,
              onChunkDone: bumpProgress, throwIfCancelled: throwIfCancelled));
        } else {
          attachments.add(await _uploadSingleMedia(
              mediaRepo, chatId, messageId, index, f, uploadedPaths));
          bumpProgress();
        }
      }
      // Last chance to abort before the message row is created — after this the
      // send is committed (recipients can fetch it).
      throwIfCancelled();

      // 3. One envelope carries all items + the shared caption; signed once.
      final album = MediaAlbum(
        items: attachments,
        caption: (caption != null && caption.trim().isNotEmpty)
            ? caption.trim()
            : null,
      );
      final body = album.encode();
      final prekeys = await _claimPrekeys(chatId, memberKeys.keys);
      final encryptedForRecipients =
          await messageEncryption.encryptForAllMembers(
        body,
        memberKeys,
        context: context,
        signatureB64: await _signMessage(context, body),
        recipientPrekeys: prekeys,
      );

      // 4. Disappearing-messages TTL (same as text).
      final ttl = ref.read(chatProvider(chatId))?.messageTtlSeconds;
      final expiresAt = (ttl != null && ttl > 0)
          ? createdAt.add(Duration(seconds: ttl))
          : null;

      // 5. Insert one encrypted row per recipient (reusing the text path).
      await repo.sendEncryptedMessage(
        chatId: chatId,
        senderId: senderId,
        createdAt: createdAt,
        encryptedForRecipients: encryptedForRecipients,
        expiresAt: expiresAt,
        messageId: messageId,
      );

      // 6. Sender's local copy: the decrypted body is the album envelope.
      final receivedAt = {for (final k in memberKeys.keys) k: null};
      final readAt = {for (final k in memberKeys.keys) k: null};
      final newMessage = Message(
        id: messageId,
        chatId: chatId,
        createdAt: createdAt,
        senderId: senderId,
        recipientId: senderId,
        decryptedContent: body,
        receivedAt: receivedAt,
        readAt: readAt,
        expiresAt: expiresAt,
      );
      await _saveToLocal(newMessage);
      state = [...state, newMessage];

      // Bump the chat metadata for the sender's own ChatList (no NewMessageEvent
      // comes back for the sender — same reason as in sendMessage). bumpToTop
      // also cures the media-specific staleness: `createdAt` was captured at
      // upload-start, so without it a message that landed in another chat during
      // the (multi-second, chunked) upload would outrank this one.
      await ref
          .read(chatsControllerProvider.notifier)
          .updateChatMetadata(
            chatId: chatId,
            lastMessageAt: createdAt,
            bumpToTop: true,
          );

      logger.info(
        '📎 Sent media album $messageId (${attachments.length} item(s))',
        tag: 'MessagesController',
      );
    } catch (e, stackTrace) {
      // Transactional cleanup: drop every blob we managed to upload (applies to
      // a user cancel too — the partial upload is removed).
      for (final p in uploadedPaths) {
        await mediaRepo.delete(p);
      }
      if (e is MediaSendCancelledException) {
        logger.info(
          '🚫 Media album send cancelled by user — cleaned up '
          '${uploadedPaths.length} uploaded chunk(s)',
          tag: 'MessagesController',
        );
      } else {
        logger.error(
          'Failed to send media album',
          tag: 'MessagesController',
          error: e,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
  }

  /// Back-compat shim: send a single media attachment (photo/video/audio/file)
  /// with an optional caption. Delegates to [sendMediaAlbum].
  Future<void> sendMediaMessage({
    required Uint8List bytes,
    required String fileName,
    required String mime,
    String? caption,
  }) =>
      sendMediaAlbum(
        files: [OutgoingMedia.bytes(bytes, fileName: fileName, mime: mime)],
        caption: caption,
      );

  /// Single-object media (images/audio/small files): the legacy path — encrypt
  /// the whole plaintext with a fresh media key and upload one blob. A small
  /// file-PATH source (e.g. a trimmed video below the chunk threshold) is read
  /// into RAM here; large path sources take [_uploadChunkedMedia] instead.
  Future<MediaAttachment> _uploadSingleMedia(
    MediaRepository mediaRepo,
    String chatId,
    String messageId,
    int index,
    OutgoingMedia f,
    List<String> uploadedPaths,
  ) async {
    final bytes = f.bytes ?? await readFileBytes(f.sourcePath!);
    final mediaType = MediaType.fromMime(f.mime);
    final isImage = mediaType == MediaType.image;
    // Strip EXIF/GPS from images (audit L6); non-images pass through.
    final outgoing = isImage ? ImageMetadata.strip(bytes, f.mime) : bytes;
    // Read intrinsic dimensions so the recipient can reserve the right box
    // before the bytes download (#9, no scroll-flicker): images from the header,
    // videos from the native probe (rotation-correct display size).
    ({int width, int height})? dims;
    if (isImage) {
      dims = ImageMetadata.dimensions(outgoing);
    } else if (mediaType == MediaType.video) {
      dims = await VideoMetadataReader.displayDimensions(
        bytes: f.sourcePath == null ? outgoing : null,
        sourcePath: f.sourcePath,
        tag: '$messageId-$index',
      );
    }
    final compressed = await MediaCompression.maybeCompress(outgoing, f.mime);
    final enc = await messageEncryption.encryptBytes(compressed ?? outgoing);
    final path = await mediaRepo.uploadEncrypted(
      chatId: chatId,
      messageId: messageId,
      fileName: f.fileName,
      blob: enc.blob,
      index: index,
    );
    uploadedPaths.add(path);
    // Video cover frame (b): generate + encrypt + upload a tiny poster so the
    // recipient shows a real thumbnail without downloading the whole video.
    final thumb = await _uploadVideoThumb(
      mediaRepo, chatId, messageId, index, f,
      bytes: f.sourcePath == null ? outgoing : null,
      uploadedPaths: uploadedPaths,
    );
    return MediaAttachment(
      mediaType: MediaType.fromMime(f.mime),
      name: f.fileName,
      mime: f.mime,
      size: outgoing.length,
      path: path,
      keyB64: base64Encode(enc.key),
      compression: compressed != null ? MediaCompression.gzip : null,
      width: dims?.width,
      height: dims?.height,
      thumbPath: thumb?.path,
      thumbKey: thumb?.key,
    );
  }

  /// Generates, encrypts and uploads a video's cover-frame thumbnail as its own
  /// tiny media object under the message's folder (reaper-grouped with the
  /// video). Returns the object path + base64 AES key, or null for non-video /
  /// non-native senders / generation failure (the poster then stays black).
  /// The uploaded path is tracked in [uploadedPaths] for send-failure rollback.
  Future<({String path, String key})?> _uploadVideoThumb(
    MediaRepository mediaRepo,
    String chatId,
    String messageId,
    int index,
    OutgoingMedia f, {
    Uint8List? bytes,
    required List<String> uploadedPaths,
  }) async {
    if (MediaType.fromMime(f.mime) != MediaType.video) return null;
    final jpg = await VideoThumbnailer.generate(
      bytes: bytes,
      sourcePath: f.sourcePath,
      tag: '$messageId-$index',
    );
    if (jpg == null) return null;
    final enc = await messageEncryption.encryptBytes(jpg);
    final path = await mediaRepo.uploadEncryptedThumb(
      chatId: chatId,
      messageId: messageId,
      blob: enc.blob,
      index: index,
    );
    uploadedPaths.add(path);
    return (path: path, key: base64Encode(enc.key));
  }

  /// Chunked media (large files streamed from a path): split the file into
  /// fixed blocks, encrypt each independently (per-chunk AAD binds order +
  /// count → the server can't reorder/drop/splice), upload each as its own
  /// object under the messageId folder. Never holds the whole file in RAM. No
  /// EXIF/gzip (chunked = large video/binary, already incompressible).
  Future<MediaAttachment> _uploadChunkedMedia(
    MediaRepository mediaRepo,
    String chatId,
    String messageId,
    int index,
    OutgoingMedia f,
    List<String> uploadedPaths, {
    void Function()? onChunkDone,
    void Function()? throwIfCancelled,
  }) async {
    final key = messageEncryption.newMediaKey();
    final prefix =
        MediaRepository.chunkPrefixPath(chatId, messageId, attIndex: index);
    final chunkCount = await forEachFileChunk(
      f.sourcePath!,
      MediaRepository.chunkSizeBytes,
      (chunkIndex, chunkCount, chunk) async {
        // Abort between chunks when the user cancels (cleanup happens in the
        // caller's transactional catch, which deletes uploadedPaths).
        throwIfCancelled?.call();
        final aad = MessageEncryptionService.mediaChunkAad(
            messageId, index, chunkIndex, chunkCount);
        final blob = await messageEncryption.encryptChunk(chunk, key, aad: aad);
        final path = await mediaRepo.uploadEncryptedChunk(
          chatId: chatId,
          messageId: messageId,
          attIndex: index,
          chunkIndex: chunkIndex,
          blob: blob,
        );
        uploadedPaths.add(path);
        onChunkDone?.call();
      },
    );
    // Reserve the right box before download (#9): large chunked media is video,
    // so probe its rotation-correct display size from the source path.
    final dims = MediaType.fromMime(f.mime) == MediaType.video
        ? await VideoMetadataReader.displayDimensions(
            sourcePath: f.sourcePath,
            tag: '$messageId-$index',
          )
        : null;
    // Cover frame (b) from the source path — a poster without streaming the
    // whole chunked video.
    final thumb = await _uploadVideoThumb(
      mediaRepo, chatId, messageId, index, f,
      uploadedPaths: uploadedPaths,
    );
    return MediaAttachment(
      mediaType: MediaType.fromMime(f.mime),
      name: f.fileName,
      mime: f.mime,
      size: f.size,
      path: prefix,
      keyB64: base64Encode(key),
      chunkCount: chunkCount,
      chunkSize: MediaRepository.chunkSizeBytes,
      width: dims?.width,
      height: dims?.height,
      thumbPath: thumb?.path,
      thumbKey: thumb?.key,
    );
  }

  /// Edit a message the current user sent: re-encrypt the new content for all
  /// recipients and update their rows. Recipients are notified via
  /// notify_message_update (content_changed) and re-decrypt. Only the sender's
  /// own text messages can be edited.
  Future<void> editMessage(String messageId, String newContent) async {
    if (userId == null) {
      throw Exception('Cannot edit message: User not authenticated');
    }
    final senderId = userId!;
    final trimmed = newContent.trim();
    if (trimmed.isEmpty) {
      throw Exception('Cannot edit message: empty content');
    }

    final existing = state.where((m) => m.id == messageId).firstOrNull;
    if (existing == null || existing is! Message) {
      throw Exception('Cannot edit message: not found');
    }
    if (existing.senderId != senderId) {
      throw Exception('Cannot edit message: not the sender');
    }

    try {
      // Re-encrypt for every current recipient (exclude the sender).
      final memberKeys = await memberKeysRepo.getAllPublicKeys(chatId);
      memberKeys.remove(senderId);
      if (memberKeys.isEmpty) {
        throw Exception('Cannot edit message: no member keys');
      }
      // Same message id => same AAD context; a fresh signature covers the
      // edited plaintext (audit H1/M3).
      final context = MessageContext(
        chatId: chatId,
        senderId: senderId,
        messageId: messageId,
      );
      final prekeys = await _claimPrekeys(chatId, memberKeys.keys);
      final encryptedForRecipients =
          await messageEncryption.encryptForAllMembers(
        trimmed,
        memberKeys,
        context: context,
        signatureB64: await _signMessage(context, trimmed),
        recipientPrekeys: prekeys,
      );

      await repo.editEncryptedMessage(
        chatId: chatId,
        messageId: messageId,
        encryptedForRecipients: encryptedForRecipients,
      );

      // Update the sender's own local copy + UI immediately.
      final updated = existing.copyWith(
        decryptedContent: Optional(trimmed),
        editedAt: Optional(DateTime.timestamp()),
      );
      await _saveToLocal(updated);
      final idx = state.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        state = [...state.sublist(0, idx), updated, ...state.sublist(idx + 1)];
      }

      logger.info(
        '✏️ Edited message $messageId (re-encrypted for ${memberKeys.length} recipients)',
        tag: 'MessagesController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to edit message',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Remove self-destruct messages whose TTL has passed from local storage and
  /// the current state. The server reaper + messageDelete events cover other
  /// clients; this keeps the local (decrypted) copy honest.
  Future<void> _sweepExpiredMessages() async {
    try {
      final expiredIds = await localRepo.deleteExpiredMessages(chatId);
      if (expiredIds.isEmpty) return;
      final expired = expiredIds.toSet();
      state = state.where((m) => !expired.contains(m.id)).toList();
      logger.info(
        '💥 Swept ${expiredIds.length} expired message(s) in chat $chatId',
        tag: 'MessagesController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to sweep expired messages',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Tick every few seconds to drop messages whose TTL has just passed, so a
  /// self-destruct message disappears live (not only on the next chat open).
  void _startExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _sweepExpiredInState(),
    );
  }

  /// Cheap in-memory sweep: scans the already-decrypted [state] (no full
  /// local re-decrypt) and removes any message past its expiry.
  Future<void> _sweepExpiredInState() async {
    final now = DateTime.timestamp();
    final expired = state
        .whereType<Message>()
        .where((m) => m.expiresAt != null && m.expiresAt!.isBefore(now))
        .map((m) => m.id)
        .toList();
    if (expired.isEmpty) return;
    for (final id in expired) {
      await localRepo.deleteMessage(chatId, id);
    }
    final set = expired.toSet();
    state = state.where((m) => !set.contains(m.id)).toList();
    logger.info(
      '💥 Live-swept ${expired.length} expired message(s) in chat $chatId',
      tag: 'MessagesController',
    );
  }

  /// Search this chat's messages by decrypted text (client-side, local only).
  Future<List<Message>> searchMessages(String query) async {
    final results = await localRepo.searchMessages(chatId, query);
    logger.info(
      '🔎 Searched "$query" in chat $chatId → ${results.length} hits',
      tag: 'MessagesController',
    );
    return results;
  }

  /// Toggles the local favorite flag on a message (#4) and persists it (update
  /// path → mirrors to the indexed `is_favorite` column). Local-only.
  Future<void> toggleFavorite(Message message) async {
    final updated = message.copyWith(isFavorite: !message.isFavorite);
    await localRepo.saveMessage(updated, update: true);
    state = [
      for (final m in state) m.id == message.id ? updated : m,
    ];
  }

  Future<void> deleteMessage(String messageId, {bool localOnly = true}) async {
    try {
      if (!localOnly) {
        final removed = await repo.deleteMessage(chatId, messageId);
        if (removed == 0) {
          // Already read by a recipient (server keeps read messages) — the
          // unsend only takes effect locally.
          logger.warning(
            'Server kept message $messageId (already read?) — deleting locally only',
            tag: 'MessagesController',
          );
        }
      }
      await localRepo.deleteMessage(chatId, messageId);
      state = state.where((m) => m.id != messageId).toList();
      logger.info('🗑️ Deleted message: $messageId', tag: 'MessagesController');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to delete message',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<int> deleteMessagesForChat(String chatId) async {
    try {
      final deleteCount = await localRepo.deleteMessagesForChat(chatId);
      state = state.where((m) => m.chatId != chatId).toList();
      logger.info(
        '🗑️ Deleted $deleteCount messages from chat: $chatId',
        tag: 'MessagesController',
      );
      return deleteCount;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to delete messages for chat',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Handle decrypted message event (already processed by GlobalMessageHandler)
  /// Just adds the message to UI state
  void _handleDecryptedMessage(NewMessageEvent event) {
    try {
      if (userId == null) return;

      // Create message object with decrypted content
      MessageInterface message;
      if (event.senderId == null || event.messageType == MessageType.system) {
        // withDecryptedContent parses the {"action":...,"subject_name":...}
        // JSON into the action/subjectName fields formattedText needs —
        // setting decryptedContent directly (as this used to) left them
        // null, so the live bubble printed the raw JSON while a reload
        // (reading the correctly-parsed copy GlobalMessageHandler already
        // saved to local storage) looked fine. Same fix needed wherever a
        // SystemMessage gets built straight from an event's raw content.
        message = SystemMessage(
          id: event.messageId,
          chatId: event.chatId,
          recipientId: userId!,
          createdAt: event.timestamp,
        ).withDecryptedContent(event.content);
      } else {
        // Re-emitted events carry plaintext in replyToPreview ('' when the
        // preview couldn't be decrypted — treat as absent).
        final preview = event.replyToPreview;
        message = Message(
          id: event.messageId,
          chatId: event.chatId,
          senderId: event.senderId!,
          recipientId: userId!,
          decryptedContent: event.content,
          createdAt: event.timestamp,
          replyToMessageId: event.replyToMessageId,
          replyToSenderId: event.replyToSenderId,
          replyToSenderName: event.replyToSenderName,
          decryptedReplyPreview:
              (preview != null && preview.isNotEmpty) ? preview : null,
        );
      }

      // Add to state if not already present
      if (!state.any((m) => m.id == message.id)) {
        state = [...state, message];
        logger.info(
          '✓ Added decrypted message ${message.id} to UI',
          tag: 'MessagesController',
        );
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle decrypted message event',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Handle message update event for UI (read receipts)
  /// Handle a message deletion broadcast from another client: remove it locally
  /// and from the open chat's state so it disappears for everyone.
  Future<void> _handleMessageDeletedUI(MessageDeleteEvent event) async {
    try {
      await localRepo.deleteMessage(chatId, event.messageId);
      if (!mounted) return;
      state = state.where((m) => m.id != event.messageId).toList();
      logger.info(
        '🗑️ Removed deleted message ${event.messageId}',
        tag: 'MessagesController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle message deletion',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _handleMessageUpdateUI(MessageUpdateEvent event) async {
    try {
      // Check if controller is still mounted
      if (!mounted) return;

      // Find the message in the current state
      final messageIndex = state.indexWhere((m) => m.id == event.messageId);
      if (messageIndex == -1) {
        // Message not in current view, skip UI update
        return;
      }

      final message = state[messageIndex];
      if (message is! Message) {
        // Only update regular messages
        return;
      }

      // Load the updated message from local storage (already updated by GlobalMessageHandler)
      final updatedMessage = await localRepo.getMessage(
        event.chatId,
        event.messageId,
      );

      if (updatedMessage != null && updatedMessage is Message) {
        final messageDifference = compareMaps(message, updatedMessage).entries;
        if (messageDifference.isEmpty) {
          // No changes, skip UI update
          return;
        }
        final differencesString = messageDifference
            .toList()
            .map((e) {
              final key = e.key;
              final value = e.value is Map
                  ? (e.value as Map)
                        .entries
                        .map((entry) => '${entry.key}: ${entry.value}')
                        .toList()
                  : [e.value].toList();
              return '$key: ${value.join(', ')}';
            })
            .join(', ');

        logger.debug(
          '🔄 Updating message UI with read receipts: ${event.messageId}, differences: $differencesString',
          tag: 'MessagesController._handleMessageUpdateUI',
        );

        // Replace in state
        state = [
          ...state.sublist(0, messageIndex),
          updatedMessage,
          ...state.sublist(messageIndex + 1),
        ];

        logger.info(
          '✓ Updated message UI with read receipts: ${event.messageId}',
          tag: 'MessagesController',
        );
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle message update UI',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Map<String, dynamic> compareMaps(Message message, Message updatedMessage) {
    var mJ = message.toJson();
    var uJ = updatedMessage.toJson();

    return Map.fromEntries(
      {...mJ.keys, ...uJ.keys}
          .map((key) {
            var mV = mJ[key];
            var uV = uJ[key];
            if ((mV is Map && uV is Map) ? !mapEquals(mV, uV) : mV != uV) {
              return MapEntry(key, {mV, uV});
            }
            return MapEntry(key, null);
          })
          .where((element) => element.value != null),
    );
  }

  /// Fetch missed messages from server (received while offline)
  Future<void> _fetchMissedMessages(String currentUserId) async {
    try {
      // Get last sync timestamp for this chat
      final lastSyncTimestamp = await localRepo.getLastSyncTimestamp(chatId);

      logger.info(
        'Fetching missed messages from server for chat $chatId (since: $lastSyncTimestamp)',
        tag: 'MessagesController',
      );

      // Fetch messages updated after last sync (or all if never synced)
      final serverMessages = await repo.fetchInitial(
        chatId,
        currentUserId,
        since: lastSyncTimestamp,
      );

      if (serverMessages.isEmpty) {
        logger.info('No missed messages found', tag: 'MessagesController');
        return;
      }

      logger.info(
        'Found ${serverMessages.length} messages on server',
        tag: 'MessagesController',
      );

      // Get private keys for decryption (current + previous after a rotation)
      final privateKeys = await keyManager.getAllPrivateKeys(chatId);
      if (privateKeys.isEmpty) {
        logger.warning(
          'Cannot decrypt missed messages: No private key',
          tag: 'MessagesController',
        );
        return;
      }

      final existingMessages = await localRepo.loadMessageIds(chatId);
      // Earliest timestamp of a RETRYABLE (content-key-locked) failure this
      // pass. Caps the sync watermark so locked messages are re-queried after
      // unlock (audit M6/M7).
      DateTime? earliestLockedTs;
      // Process each message: decrypt and save locally
      for (final message in serverMessages) {
        try {
          // Update message if already exists locally
          final existing = existingMessages.contains(message.id);

          // Skip if encrypted_content is empty (already marked as received/read)
          // This prevents overwriting the local decrypted copy
          if (message.encryptedContent == null ||
              message.encryptedContent!.isEmpty) {
            logger.debug(
              'Skipping message ${message.id}: encrypted_content is empty (already processed)',
            );
            continue;
          }

          // Decrypt the message
          if (message.encryptedContent != null) {
            // Decrypt message
            logger.debug(
              '📥 Processing missed message: ${message.id}, ${message.encryptedContent}',
            );

            final envContext = MessageContext(
              chatId: chatId,
              senderId: message.senderId,
              messageId: message.id,
            );
            final envelope = await messageEncryption.decryptEnvelopeTryKeys(
              message.encryptedContent!,
              privateKeys,
              context: envContext,
              prekeyResolver: _resolvePrekey,
            );
            final plaintext = envelope.plaintext;

            var decryptedMessage = await _stampSigStatus(
              message.withDecryptedContent(plaintext),
              envContext,
              plaintext,
              envelope,
            );

            // Also decrypt the reply-quote preview (best-effort — a failure
            // must never drop the message; pre-fix group messages carry a
            // ciphertext only one member can decrypt).
            if (decryptedMessage is Message &&
                decryptedMessage.replyToPreview != null &&
                decryptedMessage.replyToPreview!.isNotEmpty &&
                decryptedMessage.decryptedReplyPreview == null) {
              try {
                final previewPlaintext =
                    await messageEncryption.decryptMessageTryKeys(
                  decryptedMessage.replyToPreview!,
                  privateKeys,
                  context: envContext,
                  prekeyResolver: _resolvePrekey,
                );
                decryptedMessage = decryptedMessage.copyWith(
                  decryptedReplyPreview: Optional(previewPlaintext),
                );
              } catch (e) {
                logger.debug(
                  'Reply preview of missed message ${message.id} not '
                  'decryptable (quote falls back): $e',
                );
              }
            }

            // Save to local storage
            await _saveToLocal(decryptedMessage, existing: existing);

            // Forward secrecy (P3): the message is now persisted locally, so the
            // one-time prekey it consumed can be destroyed — after this the
            // fetched ciphertext can never be unwrapped again (content + preview
            // share the same prekey). Consume-once site; delete is idempotent.
            if (envelope.prekeyId != null) {
              await ref
                  .read(prekeyManagerProvider)
                  .consume(envelope.prekeyId!);
            }

            if (!existing) {
              final existingMessage = await localRepo.getMessage(
                chatId,
                message.id,
              );
              // We just fetched & decrypted this message while syncing missed
              // messages, so acknowledge it as received — but only if it isn't
              // already marked received for us. The condition was previously
              // inverted (`!= null`), so offline-received messages never got a
              // received-receipt and the sender's delivery status stayed stuck.
              if (existingMessage != null &&
                  existingMessage.receivedAt[currentUserId] == null) {
                // Mark as received on server
                final receivedAt = await repo.markAsReceived(
                  chatId,
                  message.id,
                  currentUserId,
                );

                // Mark as received locally
                await localRepo.markAsReceived(
                  chatId,
                  message.id,
                  currentUserId,
                  timestamp: receivedAt,
                );
              }
            }

            logger.info(
              '📥 Synced missed message: ${message.id}',
              tag: 'MessagesController',
            );
          }
        } catch (e, stackTrace) {
          if (e is KeyLockedException) {
            // RETRYABLE failure (audit M6/M7): the content key was locked, so
            // this message wasn't saved and its prekey wasn't consumed (the
            // throw bypassed both). Record the earliest such timestamp so the
            // watermark below does not advance past it — otherwise the message,
            // whose server copy still exists, would never be re-queried.
            final ts = message.updatedAt ?? message.createdAt;
            if (earliestLockedTs == null || ts.isBefore(earliestLockedTs)) {
              earliestLockedTs = ts;
            }
          }
          logger.error(
            'Failed to process missed message ${message.id}',
            tag: 'MessagesController',
            error: e,
            stackTrace: stackTrace,
          );
          // Continue with next message even if one fails. PERMANENT failures
          // (undecryptable) deliberately do NOT cap the watermark, so the sync
          // never stalls forever on a never-decryptable message.
        }
      }

      // Advance the sync watermark only to the newest message we actually
      // fetched — NOT DateTime.now(). Advancing to "now" can orphan a message
      // that exists on the server but wasn't in this fetch (clock/timezone
      // skew, or a row written between the query and now): it would fall before
      // the watermark and never sync again. The max updated_at we observed is
      // the safe high-water mark, and the `> since` filter makes the next sync
      // resume exactly after it. (`updated_at` is what fetchInitial filters on.)
      // Advance to the newest message we observed, but NEVER to or past the
      // earliest RETRYABLE (content-key-locked) failure — that message and
      // everything after it must re-sync after unlock (already-saved ones are
      // `existing` → a cheap skip). If the very first message was locked,
      // `watermark` stays null and we leave the existing watermark untouched.
      DateTime? watermark;
      for (final m in serverMessages) {
        final ts = m.updatedAt ?? m.createdAt;
        if (earliestLockedTs != null && !ts.isBefore(earliestLockedTs)) {
          continue; // the locked message and all after it: do not advance over.
        }
        if (watermark == null || ts.isAfter(watermark)) {
          watermark = ts;
        }
      }
      if (watermark != null) {
        await localRepo.setLastSyncTimestamp(chatId, watermark);
      }

      logger.info(
        'Finished syncing missed messages (watermark → $watermark'
        '${earliestLockedTs != null ? ', capped: key was locked' : ''})',
        tag: 'MessagesController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to fetch missed messages',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Mark a message as read (when visible in chat)
  Future<void> markAsRead(String messageId) async {
    try {
      // Only mark messages from others as read (not our own). Use a null-safe
      // lookup: the message may have scrolled out of the loaded page, where the
      // previous `firstWhere` (no orElse) threw StateError and the read silently
      // failed instead of marking it.
      MessageInterface? message;
      for (final m in state) {
        if (m.id == messageId) {
          message = m;
          break;
        }
      }
      if (message == null ||
          message.senderId == userId ||
          message.readAt[userId] != null) {
        return; // Not loaded, our own message, or already read.
      }

      // Reciprocal read-receipt privacy: when the user has read receipts OFF,
      // skip the server RPC (mark_message_read → trigger → sender broadcast) so
      // the sender never learns the message was read (their tick honestly caps
      // at "delivered" — no fake timestamp). The content was already wiped
      // server-side on *receive* (mark_message_received), so skipping this
      // leaves nothing lingering. Still mark read LOCALLY so our own unread
      // badge / unread divider stay consistent — that state never leaves the
      // device.
      DateTime? readAt;
      // Await the PERSISTED pref before deciding — a cold start straight into a
      // chat must not fire mark_message_read using the stale `true` default when
      // the user actually has read receipts off (privacy leak).
      if (await ref.read(sendReadReceiptsProvider.notifier).resolvedValue()) {
        // Mark as read on server
        readAt = await repo.markAsRead(chatId, messageId, userId!);
      }
      // Mark as read locally (readAt == null ⇒ local repo stamps now())
      await localRepo.markAsRead(chatId, messageId, userId!, timestamp: readAt);

      logger.info(
        '✓ Marked message as read: $messageId',
        tag: 'MessagesController',
      );
    } catch (e) {
      logger.warning(
        'Failed to mark message as read: $messageId',
        tag: 'MessagesController',
        error: e,
      );
    }
  }

  /// Save message to local storage
  Future<void> _saveToLocal(
    MessageInterface message, {
    bool existing = false,
  }) async {
    try {
      await localRepo.saveMessage(message, update: existing);
    } on KeyLockedException {
      // The content key is locked (app lock engaged, audit M6/M7). This save did
      // NOT happen — swallowing it would let callers proceed as if it had. In
      // _fetchMissedMessages that means the watermark advancing past, and the
      // one-time prekey being consumed, over a message that was never persisted
      // → permanent loss. Rethrow so the caller defers (skip the prekey consume,
      // cap the watermark, retry after unlock).
      rethrow;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to save message to local storage',
        tag: 'MessagesController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _resumeSub?.cancel();
    _resubscribedSub?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<MessageInterface?> getMessage(String messageId) async {
    try {
      final message = state.firstWhere((m) => m.id == messageId);
      return message;
    } on StateError catch (_) {
      return await localRepo.getMessage(chatId, messageId);
    }
  }

  MapList subtractMaps(MapList a, MapList b) {
    MapList difference = [];
    for (final aMap in a) {
      final currentIdValue = aMap['id'];
      bool found = false;
      for (final bMap in b) {
        if (bMap['id'] == currentIdValue) {
          found = true;
          break;
        }
      }

      if (!found) {
        difference.add(aMap);
      }
    }

    return difference;
  }
}
