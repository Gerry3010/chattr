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
import '../media/shot_envelope.dart';
import '../media/media_attachment.dart';
import '../settings/media_quality_controller.dart';
import '../media/media_preview_label.dart';
import '../mentions/mention_utils.dart';
import '../messages/message_links.dart';
import '../messages/message_markdown.dart';
import '../messages/message_model.dart';
import '../messages/message_reaction_model.dart';
import '../messages/message_reactions_controller.dart';
import '../messages/messages_controller.dart';
import '../invites/invite_envelope.dart';
import '../places/place_envelope.dart';
import '../summary/summary_envelope.dart';
import '../messages/messages_local_provider.dart';
import '../profiles/avatar_url_cache.dart';
import '../profiles/profiles.dart';
import '../reports/reports_repository.dart';
import '../read_receipts/read_receipts_controller.dart';
import '../chats/chat_members_controller.dart';
import '../typing_indicator/typing_indicator_provider.dart';
import '../places/place_preview_label.dart';

/// Marker id for the synthetic "unread messages" divider row injected into the
/// chatview message list (#108). It is not a real message — the custom message
/// builder renders it as a centered separator; everything else ignores it.
const String unreadDividerMessageId = '__unread_divider__';

/// The message the "unread" divider (#108) should sit above: the earliest
/// incoming message [currentUserId] hasn't read yet. Local SQLite `readAt` is
/// the source of truth. Returns null when there is nothing unread. Pure so the
/// boundary rule is unit-testable independent of the controller/chatview.
///
/// [seenUpTo] is the lower bound: the moment this chat was last open
/// (`Chat.lastReadAt`). Everything before it has demonstrably been in front of
/// the human — whether or not it got a per-message mark.
///
/// **Why this bound is needed** (reported by Gerry, 2026-08-30: "opening it
/// often scrolls me up to this one shot I apparently never opened"). An
/// unopened shot deliberately gets NO read mark
/// (`messages_controller.markAsRead`): the same mark starts the 24-hour clock
/// on both sides, and a stamp set too early would let the bubble vanish before
/// anyone had opened it. Both rules are right in themselves — only "where did
/// the reading stop?" was derived from EXACTLY the mark that shots hold back. A
/// never-opened shot was thereby a permanent anchor: every opening jumped up to
/// it, past everything genuinely read since.
///
/// The bound solves that without touching the read mark — and it solves the
/// whole class, not only shots: whatever gets no mark in future will not haunt
/// the divider forever. It is moreover the same measure the counter in the chat
/// list already computes with (`countUnread`) — before, the two computed
/// differently.
MessageInterface? oldestUnreadIncoming(
  Iterable<MessageInterface> messages,
  String currentUserId, {
  DateTime? seenUpTo,
}) {
  MessageInterface? oldest;
  for (final m in messages) {
    if (m.senderId == currentUserId) continue;
    if (m.readAt[currentUserId] != null) continue;
    // `isAfter` and not `!isBefore`: a message sitting exactly on the mark IS
    // the mark — `lastReadAt` is set from the `createdAt` of the newest
    // message, not from the device clock.
    if (seenUpTo != null && !m.createdAt.isAfter(seenUpTo)) continue;
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

  /// Where "unread" began when the chat was opened (createdAt of the first
  /// unread message, set alongside the divider). Null when the chat opened
  /// with nothing unread. Read by the summary sheet as the `since` boundary
  /// for the "unread" scope.
  DateTime? unreadBoundary;

  /// Set by the screen when it opened the chat expecting to land on the first
  /// unread message rather than at the bottom.
  ///
  /// The fork skips its initial scroll-to-bottom whenever a jump is pending
  /// (`highlightMessageNotifier != null` at its first post-frame), so the screen
  /// parks a placeholder there BEFORE the first frame — it cannot know the real
  /// id yet, because messages load asynchronously. This flag is the promise to
  /// finish that job: once the unread boundary is known we jump to it, and if it
  /// turns out there is nothing unread after all (a stale server count) we scroll
  /// to the bottom ourselves. Without the second half the chat would open stuck
  /// at the top, which is worse than the bug we set out to fix.
  bool awaitingUnreadJump = false;

  /// When this chat was last open, captured on entering.
  ///
  /// Has to be a snapshot: `resetUnreadCount` rewrites the mark on LEAVING
  /// (`chat_view_screen.dart`, dispose), and this visit's divider wants to know
  /// the state of the PREVIOUS one. Read live, the mark would at some point be
  /// this visit's own — then everything would lie below it and there would
  /// never be a divider again.
  DateTime? _seenUpTo;

  ChatViewController(this.chatId, this.ref) : super(const ChatViewState()) {
    _seenUpTo = ref
        .read(chatsControllerProvider)
        .where((c) => c.id == chatId)
        .firstOrNull
        ?.lastReadAt;
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

    // Listen to typing indicators.
    //
    // Since the rework the service supplies **user ids**, not names — the
    // display name no longer travels over the presence channel (see
    // TypingIndicatorService). It is resolved here, from the profile data this
    // chat has loaded anyway.
    ref.listen<AsyncValue<List<String>>>(
      typingIndicatorsProvider(chatId),
      (previous, next) {
        final me = state.currentUserId;
        final typingUsers = next.maybeWhen(
          data: (ids) => [
            for (final id in ids)
              if (id != me) _displayNameFor(id),
          ],
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

    // A signed avatar URL arrives after the profile does, so the ChatUsers
    // built above would otherwise keep the initials circle until something
    // else happened to rebuild them.
    ref.listen(avatarUrlCacheProvider, (previous, next) => _syncOtherUsers());
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
        .where((m) => !isSummaryEnvelope(m.decryptedContent))
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
          // Summary machinery stays in the data layer (the summary sheet reads
          // it there) but never becomes a bubble — a request the user never
          // typed, shown as their own message, would be the feature exposing
          // its own plumbing.
          if (msg != null && !isSummaryEnvelope(msg.decryptedContent)) {
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
    final path = ref.read(profileProvider(userId))?.avatarPath;
    if (path == null || path.isEmpty) return null;
    // Signed and short-lived (00075). This is not a widget, so it reads what
    // the cache already has and asks for the rest; the listener on
    // avatarUrlCacheProvider re-runs _syncOtherUsers once a URL arrives.
    final cache = ref.read(avatarUrlCacheProvider.notifier);
    cache.ensure(kAvatarBucket, path);
    return cache.cached(kAvatarBucket, path);
  }

  /// Synchronizes updated profile information (usernames) to the `chatview.ChatController`.
  void _syncOtherUsers() {
    if (!_isChatControllerInitialized) return;

    final participants = ref.read(chatParticipantsProvider(chatId));
    final profilesMap = ref.read(
      profilesMapProvider((userIds: participants, withEmptyProfiles: true)),
    );

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
        profilePhoto: _avatarUrlFor(userId),
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
      final oldest =
          oldestUnreadIncoming(newMessages, currentUID, seenUpTo: _seenUpTo);
      if (oldest != null) {
        _insertUnreadDivider(oldest);
        // Land where reading stopped instead of at the newest message. The
        // divider goes in first so it is already in the list the jump scans.
        if (awaitingUnreadJump) {
          awaitingUnreadJump = false;
          // A frame later: the divider was only just inserted into the list and
          // the fork's scan needs the laid-out entries to measure against.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) highlightMessage(oldest.id);
          });
        }
      } else if (awaitingUnreadJump) {
        // Nothing unread after all — the badge that made us expect a jump was a
        // stale server count. Undo the suppressed initial scroll, or the chat
        // opens at the top of history.
        awaitingUnreadJump = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isChatControllerInitialized) {
            _chatController.scrollToLastMessage();
          }
        });
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
    // Remember where "unread" began when this chat was opened. The summary
    // sheet uses it as the `since` boundary for the "unread" scope — by the
    // time the user taps summarise, everything is already marked read, so
    // this snapshot is the only place that still knows the boundary.
    unreadBoundary = oldest.createdAt;
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
    final preview = shotPreviewLabel(content) ??
        (album != null
            ? mediaPreviewLabel(album)
            : placePreviewLabel(content) ??
                (content.length > 100
                    ? '${content.substring(0, 100)}...'
                    : content));
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
        // Severity for the chip's colour/icon — chatview has no field for it,
        // so it rides in the package's untyped metadata bag (see
        // systemStateKey). Read back with systemStateOf() in the builder.
        update: {systemStateKey: systemMsg.state.name},
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
      // blue ticks), reactions, and reply metadata like text messages do. A
      // shot (1.27) has a bubble of its own — and must come BEFORE the media
      // check so it never passes as an ordinary photo.
      if (ShotEnvelope.tryParse(msg.decryptedContent) != null) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      if (MediaAttachment.tryParse(msg.decryptedContent) != null) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      // Group invitations render as a join card (InviteMessageCard) — without
      // this routing the envelope shows as its raw JSON in a text bubble.
      if (InviteEnvelope.tryParse(msg.decryptedContent) != null) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      // Shared marker / calendar entry (#70) — their own cards, like the
      // invitation above. Checked before the link path: a location envelope is
      // JSON, not a URL, but keeping the structured kinds together makes the
      // ordering rule obvious ("envelopes first, then prose").
      if (LocationEnvelope.tryParse(msg.decryptedContent) != null ||
          EventEnvelope.tryParse(msg.decryptedContent) != null) {
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
      // AnyLinkPreview card, which rendered as a big empty white block. A bare
      // e-mail address counts too: otherwise it would stay in the package
      // bubble, which does not link at all. It still gets no preview card there
      // — that hangs on [extractUrls].
      if (extractUrls(msg.decryptedContent).isNotEmpty ||
          extractEmails(msg.decryptedContent).isNotEmpty) {
        return msg.toChatViewMessage(
          reactions: reactions,
          chatViewType: chatview.MessageType.custom,
          showReadReceipts: showReadReceipts,
        );
      }
      // A plain message whose only special content is an @-mention needs the
      // custom builder too (MarkdownMessageBubble highlights it; the package's
      // own text bubble renders it unstyled).
      if (hasAnyMention(
        msg.decryptedContent ?? '',
        memberMentionUsernames(state.usernames),
      )) {
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

  /// Remove a message from THIS device only — the other side keeps theirs.
  ///
  /// Final, and without a tombstone: the catch-up run only fetches rows with
  /// `received_at IS NULL` (`fetchUndelivered`), and a message this device
  /// already has is long since marked received server-side with its ciphertext
  /// deleted. So it cannot come back at all.
  Future<void> deleteMessageForMe(String messageId) async {
    await ref
        .read(messagesControllerProvider(chatId).notifier)
        .deleteMessage(messageId);
  }

  /// Send an encrypted media album (one or more photos/videos/audio/files)
  /// with an optional shared caption (#109/#110). Matches the `AttachSend`
  /// callback shape used by the attach sheet / camera / clipboard.
  ///
  /// The send survives leaving the chat: both this controller and the
  /// messages controller are autoDispose, so without the keepAlive links a
  /// back-gesture mid-upload disposed them and the in-flight send threw.
  Future<void> sendMedia({
    required List<OutgoingMedia> items,
    String? caption,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
    MediaQuality? quality,
    bool asShot = false,
  }) async {
    final keepAliveLink = ref.keepAlive();
    try {
      await ref
          .read(messagesControllerProvider(chatId).notifier)
          .sendMediaAlbum(
            files: items,
            caption: caption,
            onProgress: onProgress,
            isCancelled: isCancelled,
            quality: quality,
            asShot: asShot,
          );
    } finally {
      keepAliveLink.close();
    }
  }

  /// A shot was viewed: mark it read (that is both the notice to the sender AND
  /// the start of the 24-hour clock on both sides) and burn it afterwards.
  ///
  /// The order is deliberate: the mark first, then the burn. The other way
  /// round the envelope would be emptied first, and the read mark would hit a
  /// message that is already nothing.
  Future<void> shotWasViewed(String messageId) async {
    final messages = ref.read(messagesControllerProvider(chatId).notifier);
    await messages.markAsRead(messageId, shotOpened: true);
    await messages.consumeShot(messageId);
  }

  /// Search this chat's messages by decrypted text content.
  Future<List<Message>> searchMessages(String query) =>
      ref.read(messagesControllerProvider(chatId).notifier).searchMessages(query);

  /// The display name for a user id, for the typing indicator.
  ///
  /// Falls back to the placeholder when the profile is not (yet) loaded —
  /// better "somebody is typing" than a raw id in the header.
  String _displayNameFor(String userId) {
    final name = state.usernames[userId];
    return (name != null && name.isNotEmpty)
        ? name
        : 'chat_view.someone'.tr();
  }

  /// Updates the current user's typing status on the server.
  void setTyping(bool isTyping) {
    final currentUserId = state.currentUserId;
    if (currentUserId == null) return;

    final typingService = ref.read(typingIndicatorServiceProvider);
    if (isTyping) {
      // The id only — the name stays on the device.
      typingService.startTyping(chatId: chatId, userId: currentUserId);
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
