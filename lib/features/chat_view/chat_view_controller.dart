// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../../core/helpers/hash_helper.dart';
import '../../core/logging/logger_service.dart';
import '../../core/models/optional.dart';
import '../auth/auth_controller.dart';
import '../../core/crypto/message_context.dart';
import '../../core/security/security_providers.dart';
import '../chats/chat_model.dart';
import '../chats/chats_controller.dart';
import '../media/media_attachment.dart';
import '../messages/message_links.dart';
import '../messages/message_markdown.dart';
import '../messages/message_model.dart';
import '../messages/message_reaction_model.dart';
import '../messages/message_reactions_controller.dart';
import '../messages/messages_controller.dart';
import '../messages/messages_local_provider.dart';
import '../profiles/profiles.dart';
import '../reports/reports_repository.dart';
import '../read_receipts/read_receipts_controller.dart';
import '../chats/chat_members_controller.dart';
import '../typing_indicator/typing_indicator_provider.dart';

/// Marker id for the synthetic "unread messages" divider row injected into the
/// chatview message list (#108). It is not a real message — the custom message
/// builder renders it as a centered separator; everything else ignores it.
const String unreadDividerMessageId = '__unread_divider__';

/// The message the "unread" divider (#108) should sit above: the earliest
/// incoming message [currentUserId] hasn't read yet. Local SQLite `readAt` is
/// the source of truth. Returns null when there is nothing unread. Pure so the
/// boundary rule is unit-testable independent of the controller/chatview.
MessageInterface? oldestUnreadIncoming(
  Iterable<MessageInterface> messages,
  String currentUserId,
) {
  MessageInterface? oldest;
  for (final m in messages) {
    if (m.senderId == currentUserId) continue;
    if (m.readAt[currentUserId] != null) continue;
    if (oldest == null || m.createdAt.isBefore(oldest.createdAt)) oldest = m;
  }
  return oldest;
}

/// Provider that computes participants list for a chat by combining
/// message senders and current chat members.
final chatParticipantsProvider = Provider.autoDispose
    .family<List<String>, String>((ref, chatId) {
      final messages = ref.watch(messagesControllerProvider(chatId));
      final membersAsync = ref.watch(chatMembersProvider(chatId));

      // Extract all sender IDs. The pseudo-sender 'system' must not become a
      // participant: it has no profile, so _syncOtherUsers would register it
      // with the "loading" placeholder name, which chatview then renders as
      // a sender label above every system chip.
      final senderIds = messages
          .where((m) => m.senderId.isNotEmpty && m.senderId != systemId)
          .map((m) => m.senderId)
          .toSet();

      // Get members to include in participants
      return membersAsync.maybeWhen(
        data: (members) => {...members, ...senderIds}.toList(),
        orElse: () => senderIds.toList(),
      );
    });

/// State for the ChatView feature, encapsulating all data needed for the UI.
class ChatViewState {
  /// All messages currently loaded for this chat.
  final List<MessageInterface> messages;

  /// Map of user IDs to display names for all participants.
  final Map<String, String> usernames;

  /// Whether more messages are currently being loaded.
  final bool isLoading;

  /// Error message to display if something went wrong.
  final String? error;

  /// Whether there are more older messages to load from the server.
  final bool hasMoreMessages;

  /// The chat metadata (name, type, etc.).
  final Chat? chat;

  /// Whether the current user is NOT a member of this chat.
  final bool isNotMember;

  /// Whether the current user's membership is pending approval.
  final bool isPending;

  /// List of usernames currently typing in this chat.
  final List<String> typingUsers;

  /// Current user's unique ID.
  final String? currentUserId;

  /// Current user's display name.
  final String? currentUserName;

  const ChatViewState({
    this.messages = const [],
    this.usernames = const {},
    this.isLoading = false,
    this.error,
    this.hasMoreMessages = true,
    this.chat,
    this.isNotMember = false,
    this.isPending = false,
    this.typingUsers = const [],
    this.currentUserId,
    this.currentUserName,
  });

  ChatViewState copyWith({
    List<MessageInterface>? messages,
    Map<String, String>? usernames,
    bool? isLoading,
    String? error,
    bool? hasMoreMessages,
    Chat? chat,
    bool? isNotMember,
    bool? isPending,
    List<String>? typingUsers,
    String? currentUserId,
    String? currentUserName,
  }) {
    return ChatViewState(
      messages: messages ?? this.messages,
      usernames: usernames ?? this.usernames,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      chat: chat ?? this.chat,
      isNotMember: isNotMember ?? this.isNotMember,
      isPending: isPending ?? this.isPending,
      typingUsers: typingUsers ?? this.typingUsers,
      currentUserId: currentUserId ?? this.currentUserId,
      currentUserName: currentUserName ?? this.currentUserName,
    );
  }
}

/// Controller that manages all data and logic for the chat view.
///
/// It coordinates multiple backend controllers (messages, reactions, members, typing)
/// and provides a synchronized state for the UI, including the `chatview.ChatController`.
class ChatViewController extends StateNotifier<ChatViewState> {
  final String chatId;
  final Ref ref;

  /// The controller used by the `chatview` package for UI state.
  late chatview.ChatController _chatController;

  /// Drives the fork's jump-to-message + pulse (p18). The screen sets a message
  /// id (favorites / global-search tap) and the chat list scrolls + highlights.
  final ValueNotifier<String?> highlightNotifier = ValueNotifier(null);

  /// Jump to + pulse a message by id (no-op if it's outside the loaded window).
  void highlightMessage(String messageId) =>
      highlightNotifier.value = messageId;

  /// Tracks if the chatview controller has been initialized with the initial data.
  bool _isChatControllerInitialized = false;

  // Cache for hashing to optimize UI updates and prevent redundant synchronization
  BigInt? _lastMessagesHash;
  Map<String, BigInt>? _lastMessageHashes;

  // "Unread messages" divider (#108). Computed exactly once, on the first batch
  // of unread incoming messages when the chat opens — so the divider stays put
  // even after those messages get marked read during the session. Local only.
  bool _unreadBoundaryComputed = false;

  ChatViewController(this.chatId, this.ref) : super(const ChatViewState()) {
    _initialize();
  }

  /// Exposed chatview controller for the UI components.
  chatview.ChatController get chatController => _chatController;

  /// Initial setup of the controller and its dependencies.
  void _initialize() {
    final currentUserId = ref.read(authControllerProvider);
    final currentUserName = currentUserId != null
        ? ref.read(usernameProvider(currentUserId))
        : null;

    _chatController = chatview.ChatController(
      initialMessageList: [],
      scrollController: ScrollController(),
      currentUser: chatview.ChatUser(
        id: currentUserId ?? '',
        name: currentUserName ?? '',
        profilePhoto: _avatarUrlFor(currentUserId),
      ),
      otherUsers: [chatview.ChatUser(id: systemId, name: '')],
    );

    _setupListeners();
    _updateState();
  }

  /// Subscribes to various data streams and updates the state/UI accordingly.
  void _setupListeners() {
    // Listen to messages
    ref.listen<List<MessageInterface>>(
      messagesControllerProvider(chatId),
      (previous, next) {
        _updateState();
        _syncChatController(next);
        _markNewMessagesAsRead(previous, next);
      },
    );

    // Listen to reactions
    ref.listen<Map<String, List<ReactionSummary>>>(
      chatReactionsProvider(chatId),
      (previous, next) {
        _handleReactionsChange(previous, next);
      },
    );

    // Listen to chat info
    ref.listen<Chat?>(chatProvider(chatId), (previous, next) {
      state = state.copyWith(chat: next);
    });

    // Listen to the member list itself. Without this, approving a new member
    // (or being removed) only took effect once an unrelated message arrived,
    // because `usernames`/participant count are derived in `_updateState()`.
    // This kept the admin's send field disabled and the header stuck at the
    // old member count right after an approval.
    ref.listen<AsyncValue<List<String>>>(
      chatMembersProvider(chatId),
      (previous, next) {
        _updateState();
        _syncOtherUsers();
      },
    );

    // Listen to membership status
    final currentUserId = ref.read(authControllerProvider);
    if (currentUserId != null) {
      // While the (autoDispose, network-backed) membership providers are
      // loading, KEEP the previous value instead of assuming "not a member".
      // Defaulting to true here made the red "no longer a member" banner
      // flash on every chat open / app resume until the query returned.
      ref.listen<AsyncValue<bool>>(
        isMemberProvider((chatId: chatId, userId: currentUserId)),
        (previous, next) {
          state = state.copyWith(
            isNotMember: next.maybeWhen(
              data: (v) => !v,
              orElse: () => state.isNotMember,
            ),
          );
        },
      );

      ref.listen<AsyncValue<bool>>(
        isPendingMemberProvider((chatId: chatId, userId: currentUserId)),
        (previous, next) {
          state = state.copyWith(
            isPending: next.maybeWhen(
              data: (v) => v,
              orElse: () => state.isPending,
            ),
          );
        },
      );
    }

    // Listen to typing indicators
    ref.listen<AsyncValue<List<String>>>(
      typingIndicatorsProvider(chatId),
      (previous, next) {
        final currentUserName = state.currentUserName;
        final typingUsers = next.maybeWhen(
          data: (users) => users.where((u) => u != currentUserName).toList(),
          orElse: () => <String>[],
        );
        state = state.copyWith(typingUsers: typingUsers);
        _chatController.setTypingIndicator = typingUsers.isNotEmpty;
      },
    );

    // Listen to profiles changes
    ref.listen(profilesControllerProvider, (previous, next) {
      _updateState();
      _syncOtherUsers();
    });
  }

  /// Aggregates data from multiple providers to update the unified [ChatViewState].
  /// This ensures the UI has a consistent view of all relevant chat data.
  void _updateState() {
    final currentUserId = ref.read(authControllerProvider);
    if (currentUserId == null) return;

    final currentUserName = ref.read(usernameProvider(currentUserId));
    final messages = ref.read(messagesControllerProvider(chatId));
    final participants = ref.read(chatParticipantsProvider(chatId));

    final profilesMap = ref.read(
      profilesMapProvider((userIds: participants, withEmptyProfiles: true)),
    );

    final usernameMap = profilesMap.map((k, v) => MapEntry(k, v?.username ?? 'common.loading'.tr()));

    final membershipStatus = ref.read(
      isMemberProvider((chatId: chatId, userId: currentUserId)),
    );
    // Loading/error → keep the previous value (see the listener above);
    // the initial state defaults to "member" so no banner flashes.
    final isNotMember = membershipStatus.maybeWhen(
      data: (v) => !v,
      orElse: () => state.isNotMember,
    );

    final pendingStatus = ref.read(
      isPendingMemberProvider((chatId: chatId, userId: currentUserId)),
    );
    final isPending = pendingStatus.maybeWhen(
      data: (v) => v,
      orElse: () => state.isPending,
    );

    state = state.copyWith(
      messages: messages,
      usernames: usernameMap,
      currentUserId: currentUserId,
      currentUserName: currentUserName,
      isNotMember: isNotMember,
      isPending: isPending,
      chat: ref.read(chatProvider(chatId)),
      hasMoreMessages: ref.read(messagesControllerProvider(chatId).notifier).hasMore,
    );

    if (!_isChatControllerInitialized) {
      _initializeChatControllerData(messages, currentUserId, currentUserName, usernameMap);
      _isChatControllerInitialized = true;
      // Register all known members up front so an incoming message from a
      // member who hasn't sent anything yet doesn't hit chatview's
      // "User not found" throw (renders as a red error bubble in debug).
      _syncOtherUsers();
    }
  }

  /// Performs the heavy initial synchronization between our local message models
  /// and the `chatview` package's expected format.
  void _initializeChatControllerData(
    List<MessageInterface> messages,
    String currentUserId,
    String currentUserName,
    Map<String, String> usernameMap,
  ) {
    final reactionsMap = ref.read(chatReactionsProvider(chatId));
    final chatMessages = messages
        .map((m) => _convertMessage(m, reactionsMap))
        .toList();

    final allSenderIds = messages
        .where((m) => m.senderId != currentUserId && m.isUserMessage)
        .map((m) => m.senderId)
        .toSet();

    final replyTargetIds = messages
        .where((m) => m is Message && m.replyToSenderId != null)
        .map((m) => (m as Message).replyToSenderId!)
        .where((id) => id != currentUserId)
        .toSet();

    // Reactors need to resolve via getUserFromId too (the reaction chips and
    // the "who reacted" sheet look them up), and they aren't necessarily
    // senders. During this rebuild _convertMessage's _ensureUserRegistered
    // still targets the OLD controller, so seed them into the initial list —
    // along with all current participants (usernameMap keys).
    final reactorIds = reactionsMap.values
        .expand((summaries) => summaries)
        .expand((s) => s.userIds)
        .where((id) => id != currentUserId)
        .toSet();

    final allUserIds = {
      ...allSenderIds,
      ...replyTargetIds,
      ...reactorIds,
      ...usernameMap.keys,
    }..remove(currentUserId);

    final otherUsers = allUserIds.map((senderId) {
      final name = usernameMap[senderId] ?? 'common.loading'.tr();
      return chatview.ChatUser(
        id: senderId,
        name: name,
        profilePhoto: _avatarUrlFor(senderId),
      );
    }).toList();
    otherUsers.add(chatview.ChatUser(id: systemId, name: ''));

    _chatController.dispose();
    _chatController = chatview.ChatController(
      initialMessageList: chatMessages,
      scrollController: ScrollController(),
      otherUsers: otherUsers,
      currentUser: chatview.ChatUser(
        id: currentUserId,
        name: currentUserName,
        profilePhoto: _avatarUrlFor(currentUserId),
      ),
    );

    _updateHashes(messages, otherUsers);

    // Reactions that already exist on the server (added while this chat was
    // closed) are not covered by realtime events — prime them explicitly.
    _primeReactions(messages);
  }

  /// Batch-loads existing reactions for [messages] into the chat-wide
  /// reactions state ([chatReactionsProvider]). The event bus only delivers
  /// reaction changes that happen while the app is connected, so messages
  /// that get loaded, paged in, or resynced must be primed here; the
  /// provider listener then re-renders the affected bubbles.
  void _primeReactions(Iterable<MessageInterface> messages) {
    final ids =
        messages.where((m) => m.isUserMessage).map((m) => m.id).toList();
    if (ids.isEmpty) return;
    unawaited(
      ref
          .read(chatReactionsProvider(chatId).notifier)
          .loadReactionsForMessages(ids),
    );
  }

  void _updateHashes(List<MessageInterface> messages, List<chatview.ChatUser> otherUsers) {
    final messagesMap = {for (final m in messages) m.id: m};
    _lastMessageHashes = getMapValuesHash(messagesMap);
    _lastMessagesHash = getHash(_lastMessageHashes);
  }

  /// Synchronizes changes from the message list to the `chatview.ChatController`.
  /// Uses hashing and diffing to only apply necessary updates (add/update).
  void _syncChatController(List<MessageInterface> messages) {
    if (!_isChatControllerInitialized) return;

    final messagesMap = {for (final m in messages) m.id: m};
    final currentMessageHashes = getMapValuesHash(messagesMap);
    final currentMessagesHash = getHash(currentMessageHashes);

    if (currentMessagesHash == _lastMessagesHash) return;

    // Keep participant names/avatars fresh on the chatview controller before
    // adding messages. A sender that isn't a known participant yet no longer
    // needs pre-registering: our chatview_utils fork's getUserFromId returns a
    // fallback ChatUser instead of throwing, so an unknown id renders as its id
    // for a moment (until _syncOtherUsers upgrades it) rather than crashing the
    // whole list.
    _syncOtherUsers();

    final reactionsMap = ref.read(chatReactionsProvider(chatId));
    final diff = getMapDiff(_lastMessageHashes, currentMessageHashes);

    final addedMessages = <MessageInterface>[];
    for (final difference in diff.entries) {
      final msg = messagesMap[difference.key];
      switch (difference.value.status) {
        case MapEntryStatus.added:
          if (msg != null) {
            final alreadyExists = _chatController.initialMessageList.any((m) => m.id == msg.id);
            if (!alreadyExists) {
              _chatController.addMessage(_convertMessage(msg, reactionsMap));
              addedMessages.add(msg);
            }
          }
          break;
        case MapEntryStatus.removed:
          // Our chatview_utils fork adds removeMessage (list + stream). Upstream
          // had no remove API, forcing a manual initialMessageList mutate + sink
          // poke here.
          _chatController.removeMessage(difference.key);
          break;
        case MapEntryStatus.changed:
          if (msg != null) {
            _chatController.updateMessage(
              messageId: msg.id,
              newMessage: _convertMessage(msg, reactionsMap),
            );
          }
          break;
      }
    }

    _lastMessageHashes = currentMessageHashes;
    _lastMessagesHash = currentMessagesHash;

    // Paged-in / resynced messages may carry reactions the event bus never
    // delivered (added while offline or before the chat was opened).
    _primeReactions(addedMessages);
  }

  /// Resolves a user's avatar URL for the chatview `ChatUser.profilePhoto` so
  /// reaction chips (and the "who reacted" sheet) show the real picture instead
  /// of the initials fallback. Returns null when no profile/avatar is known
  /// (then chatview renders the initials circle — the intended fallback).
  String? _avatarUrlFor(String? userId) {
    if (userId == null || userId.isEmpty) return null;
    final profile = ref.read(profileProvider(userId));
    return ref
        .read(profilesControllerProvider.notifier)
        .avatarUrl(profile?.avatarPath);
  }

  /// Synchronizes updated profile information (usernames) to the `chatview.ChatController`.
  void _syncOtherUsers() {
    if (!_isChatControllerInitialized) return;

    final participants = ref.read(chatParticipantsProvider(chatId));
    final profilesMap = ref.read(
      profilesMapProvider((userIds: participants, withEmptyProfiles: true)),
    );

    final profilesNotifier = ref.read(profilesControllerProvider.notifier);
    for (final entry in profilesMap.entries) {
      final userId = entry.key;
      final profile = entry.value;
      if (userId == state.currentUserId) continue;

      if (profile == null) {
        logger.debug('syncOtherUsers: no profile for $userId',
            tag: 'ChatViewController');
      }
      final chatUser = chatview.ChatUser(
        id: userId,
        name: profile?.username ?? 'common.loading'.tr(),
        profilePhoto: profilesNotifier.avatarUrl(profile?.avatarPath),
      );
      _chatController.updateOtherUser(chatUser);
    }
  }

  /// Handles changes in message reactions and updates the affected messages in the UI.
  void _handleReactionsChange(
    Map<String, List<ReactionSummary>>? previous,
    Map<String, List<ReactionSummary>> next,
  ) {
    if (!_isChatControllerInitialized) return;

    final changedMessageIds = <String>{};
    next.forEach((messageId, reactions) {
      if (previous == null || previous[messageId] != reactions) {
        changedMessageIds.add(messageId);
      }
    });

    previous?.forEach((messageId, reactions) {
      if (!next.containsKey(messageId)) {
        changedMessageIds.add(messageId);
      }
    });

    final messages = ref.read(messagesControllerProvider(chatId));
    final messagesMap = {for (final m in messages) m.id: m};

    for (final messageId in changedMessageIds) {
      final msg = messagesMap[messageId];
      if (msg != null) {
        // Our fork's updateMessage no-ops for ids not in its list (e.g. a
        // reaction on a message beyond the loaded page) instead of throwing
        // 'Message Not Found!' and aborting this whole loop.
        _chatController.updateMessage(
          messageId: messageId,
          newMessage: _convertMessage(msg, next),
        );
      }
    }
  }

  /// Automatically marks incoming messages as read when they are viewed in the chat.
  void _markNewMessagesAsRead(List<MessageInterface>? previous, List<MessageInterface> next) {
    if (previous == null || state.currentUserId == null) return;

    final currentUID = state.currentUserId!;
    final previousIds = previous.map((m) => m.id).toSet();
    final newMessages = next
        .where(
          (m) =>
              !previousIds.contains(m.id) &&
              m.senderId != currentUID &&
              m.readAt[currentUID] == null,
        )
        .toList();

    // Freeze the "unread" divider boundary exactly once, on the first batch of
    // unread incoming messages — BEFORE the loop below marks them read (which
    // would otherwise erase the boundary). Messages that arrive later while the
    // chat is open are read immediately and never sit under a divider.
    if (!_unreadBoundaryComputed) {
      _unreadBoundaryComputed = true;
      final oldest = oldestUnreadIncoming(newMessages, currentUID);
      if (oldest != null) {
        _insertUnreadDivider(oldest);
      }
    }

    if (newMessages.isEmpty) return;

    final messagesNotifier = ref.read(messagesControllerProvider(chatId).notifier);
    final chatsController = ref.read(chatsControllerProvider.notifier);

    for (final m in newMessages) {
      messagesNotifier.markAsRead(m.id);
    }
    chatsController.resetUnreadCount(chatId);
  }

  /// Injects the synthetic "unread messages" divider directly BEFORE [oldest]
  /// (the first unread incoming message). chatview renders in insertion order
  /// (its `sortEnable` is off), so `addMessage()` would append the divider to
  /// the very bottom regardless of `createdAt`; we instead insert it at the
  /// right index in `initialMessageList` and nudge the stream the same way
  /// `ChatController.addMessage` does internally. The divider carries no real
  /// message id, so `_syncChatController`'s diff (keyed on chattr message ids)
  /// never touches or removes it.
  void _insertUnreadDivider(MessageInterface oldest) {
    if (!_isChatControllerInitialized) return;
    final list = _chatController.initialMessageList;
    if (list.any((m) => m.id == unreadDividerMessageId)) return;
    final index = list.indexWhere((m) => m.id == oldest.id);
    if (index < 0) return;
    list.insert(
      index,
      chatview.Message(
        id: unreadDividerMessageId,
        // createdAt kept just before `oldest` for correctness if sorting is ever
        // enabled; position here is driven by the insertion index above.
        message: '',
        createdAt: oldest.createdAt.subtract(const Duration(milliseconds: 1)),
        sentBy: systemId,
        messageType: chatview.MessageType.custom,
        status: chatview.MessageStatus.read,
      ),
    );
    final stream = _chatController.messageStreamController;
    if (!stream.isClosed) stream.sink.add(list);
  }

  /// Fills in a missing reply-quote plaintext from the loaded original
  /// message. Covers legacy messages (whose single shared preview ciphertext
  /// most group members can't decrypt) and any preview that failed to
  /// decrypt. Returns [msg] unchanged when there's nothing to resolve.
  Message _resolveReplyPreview(Message msg) {
    final replyId = msg.replyToMessageId;
    if (replyId == null || replyId.isEmpty) return msg;
    if (msg.decryptedReplyPreview != null &&
        msg.decryptedReplyPreview!.isNotEmpty) {
      return msg;
    }

    final original = ref
        .read(messagesControllerProvider(chatId))
        .where((m) => m.id == replyId)
        .firstOrNull;
    final content = original?.decryptedContent;
    if (content == null || content.isEmpty) return msg;

    // Media originals carry their attachment JSON as content — label instead.
    final album = MediaAlbum.tryParse(content);
    final preview = album != null
        ? album.previewLabel
        : (content.length > 100 ? '${content.substring(0, 100)}...' : content);
    return msg.copyWith(decryptedReplyPreview: Optional(preview));
  }

  /// Converts our internal message interface to the format expected by the `chatview` package.
  chatview.Message _convertMessage(
    MessageInterface msg,
    Map<String, List<ReactionSummary>> reactionsMap,
  ) {
    final summaries = reactionsMap[msg.id] ?? [];
    // chatview's Reaction is a pair of PARALLEL lists — one emoji entry per
    // reacting user plus that user's id at the same index. The chip's count
    // and the "who reacted" bottom sheet both read reactedUserIds; passing
    // an empty list rendered that sheet blank. Pre-00035 payloads have no
    // user_ids — fall back to the bare emoji (sheet stays empty, no crash).
    final reactions = summaries.map((s) {
      // Reactors aren't necessarily participants. The chatview_utils fork's
      // getUserFromId returns a fallback for unknown ids (no throw), so no
      // pre-registration is needed; known participants get their real names
      // from _syncOtherUsers.
      return chatview.Reaction(
        reactions: s.userIds.isEmpty
            ? [s.reaction]
            : List.filled(s.userIds.length, s.reaction),
        reactedUserIds: s.userIds,
      );
    }).toList();

    if (msg.isSystemMessage) {
      final systemMsg = msg as SystemMessage;
      return chatview.Message(
        id: msg.id,
        message: _formatSystemMessage(systemMsg),
        createdAt: msg.createdAt,
        sentBy: systemId,
        messageType: chatview.MessageType.custom,
        status: chatview.MessageStatus.read,
      );
    } else if (msg is Message) {
      // Reply quote missing its plaintext (pre-fix message, or the preview
      // ciphertext wasn't decryptable for us)? Resolve it from the original
      // message if that one is loaded — better than showing "[Encrypted]".
      msg = _resolveReplyPreview(msg);
      // Reciprocal read-receipt privacy: hide others' read state on our own
      // bubbles when the local user has read receipts off (see
      // sendReadReceiptsProvider). Read once per conversion.
      final showReadReceipts = ref.read(sendReadReceiptsProvider);
      // Media attachments render via a custom builder (image inline / file
      // card). Convert through toChatViewMessage so they carry their real
      // delivery/read status (was hardcoded "read" — receipts always showed
      // blue ticks), reactions, and reply metadata like text messages do.
      if (MediaAttachment.tryParse(msg.decryptedContent) != null) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      // Markdown-formatted text goes through the custom builder
      // (MarkdownMessageBubble). Checked before links so `[text](url)` renders
      // as a formatted link rather than a preview card.
      if (hasMarkdown(msg.decryptedContent ?? '')) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      // Link-containing texts also go through the custom builder
      // (LinkMessageBubble): chatview's own text bubble hard-wires the
      // AnyLinkPreview card, which rendered as a big empty white block.
      if (extractUrls(msg.decryptedContent).isNotEmpty) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      return msg.toChatViewMessage(
        reactions: reactions,
        showReadReceipts: showReadReceipts,
      );
    } else {
      return chatview.Message(
        id: msg.id,
        message: msg.decryptedContent ?? 'chat_view.encrypted'.tr(),
        createdAt: msg.createdAt,
        sentBy: msg.senderId,
        messageType: chatview.MessageType.text,
      );
    }
  }

  // Formatting itself lives on SystemMessage.formattedText (message_model.dart)
  // so every consumer (this bubble, the live UI-state path in
  // messages_controller.dart, the notification banner) uses the same logic
  // — previously duplicated here and subtly different from the two other
  // call sites, which is how "manchmal raw JSON statt Text" happened.
  String _formatSystemMessage(SystemMessage msg) => msg.formattedText;

  /// Load more (older) messages
  Future<void> loadMoreMessages() async {
    if (state.isLoading || !state.hasMoreMessages) return;

    state = state.copyWith(isLoading: true);
    try {
      final messagesNotifier = ref.read(messagesControllerProvider(chatId).notifier);
      await messagesNotifier.loadMore();
      state = state.copyWith(isLoading: false, hasMoreMessages: messagesNotifier.hasMore);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Sends a new message to the chat, including optional reply information.
  Future<void> sendMessage(String message, {chatview.ReplyMessage? replyMessage}) async {
    if (state.currentUserId == null || message.trim().isEmpty) return;

    try {
      final newMessage = await ref
          .read(messagesControllerProvider(chatId).notifier)
          .sendMessage(
            message.trim(),
            replyToMessageId: replyMessage?.messageId,
          );

      if (!_chatController.initialMessageList.any((m) => m.id == newMessage.id)) {
        _chatController.addMessage(newMessage.toChatViewMessage(
          showReadReceipts: ref.read(sendReadReceiptsProvider),
        ));
      }
    } catch (e) {
      logger.error('Failed to send message: $e');
      rethrow;
    }
  }

  /// Edit one of the current user's own messages (re-encrypts for recipients).
  Future<void> editMessage(String messageId, String newContent) async {
    await ref
        .read(messagesControllerProvider(chatId).notifier)
        .editMessage(messageId, newContent);
  }

  /// Delete a message for everyone (server + local + propagated via messageDelete).
  Future<void> deleteMessageForEveryone(String messageId) async {
    await ref
        .read(messagesControllerProvider(chatId).notifier)
        .deleteMessage(messageId, localOnly: false);
  }

  /// Send an encrypted media album (one or more photos/videos/audio/files)
  /// with an optional shared caption (#109/#110). Matches the `AttachSend`
  /// callback shape used by the attach sheet / camera / clipboard.
  Future<void> sendMedia({
    required List<OutgoingMedia> items,
    String? caption,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  }) =>
      ref.read(messagesControllerProvider(chatId).notifier).sendMediaAlbum(
            files: items,
            caption: caption,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );

  /// Search this chat's messages by decrypted text content.
  Future<List<Message>> searchMessages(String query) =>
      ref.read(messagesControllerProvider(chatId).notifier).searchMessages(query);

  /// Updates the current user's typing status on the server.
  void setTyping(bool isTyping) {
    final currentUserId = state.currentUserId;
    final currentUserName = state.currentUserName;
    if (currentUserId == null || currentUserName == null) return;

    final typingService = ref.read(typingIndicatorServiceProvider);
    if (isTyping) {
      typingService.startTyping(
        chatId: chatId,
        userId: currentUserId,
        username: currentUserName,
      );
    } else {
      typingService.stopTyping(chatId: chatId);
    }
  }

  /// Deletes the chat and its messages from the local database.
  Future<void> deleteChatLocally() async {
    final success = await ref
        .read(chatsControllerProvider.notifier)
        .deleteChat(chatId, localOnly: true);
    if (success) {
      // Handle navigation or state update if needed
    }
  }

  /// The accused's voluntary self-reveal: attach the plaintext of one of MY
  /// reported messages, freshly signed with my identity key over the canonical
  /// [MessageContext] bytes (self-authenticating AND plaintext-bound — stronger
  /// than a recipient reveal). Server-side `reveal_reported_message` accepts a
  /// sender self-reveal at any time. Never called for someone else's message.
  Future<void> revealReportedMessage(ReportedMessage report) async {
    final msg = await ref
        .read(messagesLocalRepositoryProvider)
        .getMessage(chatId, report.messageId);
    if (msg is! Message || msg.decryptedContent == null) {
      throw StateError('reported message is not available locally');
    }
    final text = msg.decryptedContent!;
    final context = MessageContext(
      chatId: chatId,
      senderId: msg.senderId,
      messageId: report.messageId,
    );
    final idm = ref.read(identityKeyManagerProvider);
    final sig = await idm.sign(context.signingBytes(text));
    final pub = await idm.publicKeyBase64();
    await ref.read(reportsRepositoryProvider).revealMessage(
          reportId: report.reportId,
          text: text,
          sig: sig,
          identityKey: pub,
        );
    ref.invalidate(myReportedMessagesProvider);
  }

  @override
  void dispose() {
    highlightNotifier.dispose();
    _chatController.dispose();
    super.dispose();
  }
}

/// Provider for ChatViewController
final chatViewControllerProvider = StateNotifierProvider.family
    .autoDispose<ChatViewController, ChatViewState, String>(
      (ref, chatId) => ChatViewController(chatId, ref),
    );
