// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Event Types for the central event bus
///
/// All events sent through the user-specific channel
library;

import 'package:chattr/features/messages/message_model.dart';

enum EventType {
  newMessage,
  newChat,
  chatUpdate,
  chatDeleted,
  messageUpdate,
  messageDelete,
  pendingMember,
  memberStatusChanged,
  membershipChanged,
  memberKeyRegistered,
  reactionChanged,
  profileChanged,
  chatRequest,
  callSignal,
}

/// Base event class
abstract class BusEvent {
  final EventType type;
  final DateTime timestamp;
  final bool processed;

  BusEvent({
    required this.type,
    required this.timestamp,
    this.processed = false,
  });

  BusEvent._fromJson(Map<String, dynamic> json, {required this.type})
      : processed = (json['processed'] ?? false) as bool,
        timestamp = json.containsKey('timestamp') && json['timestamp'] is String
            ? (DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now())
            : DateTime.now();

  factory BusEvent.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    final type = EventType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => throw Exception('Unknown event type: $typeStr'),
    );

    switch (type) {
      case EventType.newMessage:
        return NewMessageEvent.fromJson(json);
      case EventType.newChat:
        return NewChatEvent.fromJson(json);
      case EventType.chatUpdate:
        return ChatUpdateEvent.fromJson(
          (json['payload'] ?? json) as Map<String, dynamic>,
        );
      case EventType.chatDeleted:
        return ChatDeletedEvent.fromJson(json);
      case EventType.messageUpdate:
        return MessageUpdateEvent.fromJson(json);
      case EventType.messageDelete:
        return MessageDeleteEvent.fromJson(json);
      case EventType.pendingMember:
        return PendingMemberEvent.fromJson(json);
      case EventType.memberStatusChanged:
        return MemberStatusChangedEvent.fromJson(json);
      case EventType.membershipChanged:
        return MembershipChangedEvent.fromJson(json);
      case EventType.memberKeyRegistered:
        return MemberKeyRegisteredEvent.fromJson(json);
      case EventType.reactionChanged:
        return ReactionChangedEvent.fromJson(json);
      case EventType.profileChanged:
        return ProfileChangedEvent.fromJson(json);
      case EventType.chatRequest:
        return ChatRequestEvent.fromJson(json);
      case EventType.callSignal:
        return CallSignalEvent.fromJson(json);
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'processed': processed,
    };
  }

  BusEvent copyWith({DateTime? timestamp, bool? processed});

  BusEvent asProcessed() {
    return copyWith(processed: true);
  }

  @override
  String toString() {
    final json = toJson();
    return 'BusEvent{type: $type, timestamp: $timestamp, processed: $processed, json: $json}';
  }
}

/// New message event
class NewMessageEvent extends BusEvent {
  final String chatId;
  final String messageId;
  final String? senderId;
  final String content;
  final MessageType messageType;
  final bool decrypted;

  /// Caught up rather than arrived live.
  ///
  /// The catch-up run at startup pushes every missed message through EXACTLY
  /// the same path as one arriving live — that is deliberate and right, because
  /// decryption, prekey consumption, persistence and delivery confirmation
  /// would otherwise drift apart. Only one thing must not ride along: the
  /// notification. Otherwise ten banners pop up at once when the app is opened
  /// (reported 2026-08-19, screenshot from the iPhone).
  ///
  /// Deliberately NOT in toJson/fromJson: the marking arises exclusively
  /// locally in `catchUpEventFor()` and never travels over the wire.
  final bool catchUp;

  // Reply metadata (broadcast since migration 00029; null for non-replies and
  // for events from older trigger versions). [replyToPreview] mirrors
  // [content]'s semantics: per-recipient ciphertext while `decrypted ==
  // false`, plaintext after the GlobalMessageHandler re-emits the event.
  final String? replyToMessageId;
  final String? replyToSenderId;
  final String? replyToSenderName;
  final String? replyToPreview;

  NewMessageEvent({
    required this.chatId,
    required this.messageId,
    this.senderId,
    required this.content,
    required this.messageType,
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyToSenderName,
    this.replyToPreview,
    DateTime? timestamp,
    this.decrypted = false,
    this.catchUp = false,
    super.processed,
  }) : super(
          type: EventType.newMessage,
          timestamp: timestamp ?? DateTime.now(),
        );

  NewMessageEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        messageId = json['message_id'] as String,
        senderId = json['sender_id'] as String?,
        content = json['content'] as String,
        messageType = MessageType.from(json['message_type'] as String),
        replyToMessageId = json['reply_to_message_id'] as String?,
        replyToSenderId = json['reply_to_sender_id'] as String?,
        replyToSenderName = json['reply_to_sender_name'] as String?,
        replyToPreview = json['reply_to_preview'] as String?,
        decrypted =
            json.containsKey('decrypted') ? json['decrypted'] as bool : false,
        // What comes over the wire is live by definition — the marking arises
        // only locally in the catch-up run. Hard-coded false here rather than
        // read from the JSON: a server that ever sent the field could otherwise
        // suppress banners.
        catchUp = false,
        super._fromJson(type: EventType.newMessage);

  factory NewMessageEvent.fromJson(Map<String, dynamic> json) {
    return NewMessageEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'message_id': messageId,
      'sender_id': senderId,
      'content': content,
      'message_type': messageType.name,
      'reply_to_message_id': replyToMessageId,
      'reply_to_sender_id': replyToSenderId,
      'reply_to_sender_name': replyToSenderName,
      'reply_to_preview': replyToPreview,
      'decrypted': decrypted,
    };
  }

  @override
  NewMessageEvent copyWith({
    String? chatId,
    String? messageId,
    String? senderId,
    String? content,
    MessageType? messageType,
    String? replyToMessageId,
    String? replyToSenderId,
    String? replyToSenderName,
    String? replyToPreview,
    bool? decrypted,
    bool? catchUp,
    DateTime? timestamp,
    bool? processed,
  }) {
    return NewMessageEvent(
      chatId: chatId ?? this.chatId,
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderId: replyToSenderId ?? this.replyToSenderId,
      replyToSenderName: replyToSenderName ?? this.replyToSenderName,
      replyToPreview: replyToPreview ?? this.replyToPreview,
      decrypted: decrypted ?? this.decrypted,
      // Without this line the marking is lost when the decrypted event is re-
      // emitted — and that event is exactly what the notification path sees.
      catchUp: catchUp ?? this.catchUp,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// New chat event
class NewChatEvent extends BusEvent {
  final String chatId;

  NewChatEvent({required this.chatId, DateTime? timestamp, super.processed})
      : super(
          type: EventType.newChat,
          timestamp: timestamp ?? DateTime.now(),
        );

  NewChatEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        super._fromJson(type: EventType.newChat);

  factory NewChatEvent.fromJson(Map<String, dynamic> json) {
    return NewChatEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {...super.toJson(), 'chat_id': chatId};
  }

  @override
  NewChatEvent copyWith({
    String? chatId,
    DateTime? timestamp,
    bool? processed,
  }) {
    return NewChatEvent(
      chatId: chatId ?? this.chatId,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Chat update event
class ChatUpdateEvent extends BusEvent {
  final String chatId;
  final Map<String, dynamic> updates;

  ChatUpdateEvent({
    required this.chatId,
    required this.updates,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.chatUpdate,
          timestamp: timestamp ?? DateTime.now(),
        );

  ChatUpdateEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        updates = json['updates'] as Map<String, dynamic>,
        super._fromJson(type: EventType.chatUpdate);

  factory ChatUpdateEvent.fromJson(Map<String, dynamic> json) {
    return ChatUpdateEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {...super.toJson(), 'chat_id': chatId, 'updates': updates};
  }

  @override
  ChatUpdateEvent copyWith({
    String? chatId,
    Map<String, dynamic>? updates,
    DateTime? timestamp,
    bool? processed,
  }) {
    return ChatUpdateEvent(
      chatId: chatId ?? this.chatId,
      updates: updates ?? this.updates,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Chat deleted event
class ChatDeletedEvent extends BusEvent {
  final String chatId;

  ChatDeletedEvent(
      {required this.chatId, DateTime? timestamp, super.processed})
      : super(
          type: EventType.chatDeleted,
          timestamp: timestamp ?? DateTime.now(),
        );

  ChatDeletedEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        super._fromJson(type: EventType.chatDeleted);

  factory ChatDeletedEvent.fromJson(Map<String, dynamic> json) {
    return ChatDeletedEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {...super.toJson(), 'chat_id': chatId};
  }

  @override
  ChatDeletedEvent copyWith({
    String? chatId,
    DateTime? timestamp,
    bool? processed,
  }) {
    return ChatDeletedEvent(
      chatId: chatId ?? this.chatId,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Message update event
class MessageUpdateEvent extends BusEvent {
  final String chatId;
  final String messageId;
  final String recipientId;
  final Map<String, dynamic> updates;

  MessageUpdateEvent({
    required this.chatId,
    required this.messageId,
    required this.recipientId,
    required this.updates,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.messageUpdate,
          timestamp: timestamp ?? DateTime.now(),
        );

  MessageUpdateEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        messageId = json['message_id'] as String,
        recipientId = json['recipient_id'] as String,
        updates = json['updates'] as Map<String, dynamic>,
        super._fromJson(type: EventType.messageUpdate);

  factory MessageUpdateEvent.fromJson(Map<String, dynamic> json) {
    return MessageUpdateEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'message_id': messageId,
      'recipient_id': recipientId,
      'updates': updates,
    };
  }

  @override
  MessageUpdateEvent copyWith({
    String? chatId,
    String? messageId,
    String? recipientId,
    Map<String, dynamic>? updates,
    DateTime? timestamp,
    bool? processed,
  }) {
    return MessageUpdateEvent(
      chatId: chatId ?? this.chatId,
      messageId: messageId ?? this.messageId,
      recipientId: recipientId ?? this.recipientId,
      updates: updates ?? this.updates,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Message delete event
class MessageDeleteEvent extends BusEvent {
  final String chatId;
  final String messageId;

  MessageDeleteEvent({
    required this.chatId,
    required this.messageId,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.messageDelete,
          timestamp: timestamp ?? DateTime.now(),
        );

  MessageDeleteEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        messageId = json['message_id'] as String,
        super._fromJson(type: EventType.messageDelete);

  factory MessageDeleteEvent.fromJson(Map<String, dynamic> json) {
    return MessageDeleteEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {...super.toJson(), 'chat_id': chatId, 'message_id': messageId};
  }

  @override
  MessageDeleteEvent copyWith({
    String? chatId,
    String? messageId,
    DateTime? timestamp,
    bool? processed,
  }) {
    return MessageDeleteEvent(
      chatId: chatId ?? this.chatId,
      messageId: messageId ?? this.messageId,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Pending member event (when a user requests to join a group chat)
class PendingMemberEvent extends BusEvent {
  final String chatId;
  final String userId;

  PendingMemberEvent({
    required this.chatId,
    required this.userId,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.pendingMember,
          timestamp: timestamp ?? DateTime.now(),
        );

  PendingMemberEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        userId = json['user_id'] as String,
        super._fromJson(type: EventType.pendingMember);

  factory PendingMemberEvent.fromJson(Map<String, dynamic> json) {
    return PendingMemberEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {...super.toJson(), 'chat_id': chatId, 'user_id': userId};
  }

  @override
  PendingMemberEvent copyWith({
    String? chatId,
    String? userId,
    DateTime? timestamp,
    bool? processed,
  }) {
    return PendingMemberEvent(
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Member status changed event (when a user's membership request is accepted/rejected)
class MemberStatusChangedEvent extends BusEvent {
  final String chatId;
  final String userId;
  final bool accepted;

  MemberStatusChangedEvent({
    required this.chatId,
    required this.userId,
    required this.accepted,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.memberStatusChanged,
          timestamp: timestamp ?? DateTime.now(),
        );

  MemberStatusChangedEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        userId = json['user_id'] as String,
        accepted = json['accepted'] as bool,
        super._fromJson(type: EventType.memberStatusChanged);

  factory MemberStatusChangedEvent.fromJson(Map<String, dynamic> json) {
    return MemberStatusChangedEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'user_id': userId,
      'accepted': accepted,
    };
  }

  @override
  MemberStatusChangedEvent copyWith({
    String? chatId,
    String? userId,
    bool? accepted,
    DateTime? timestamp,
    bool? processed,
  }) {
    return MemberStatusChangedEvent(
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      accepted: accepted ?? this.accepted,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Membership changed event (when the member list of a chat changes)
class MembershipChangedEvent extends BusEvent {
  final String chatId;
  final String userId;
  final String action; // 'joined', 'left', 'approved'

  MembershipChangedEvent({
    required this.chatId,
    required this.userId,
    required this.action,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.membershipChanged,
          timestamp: timestamp ?? DateTime.now(),
        );

  MembershipChangedEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        userId = json['user_id'] as String,
        action = json['action'] as String,
        super._fromJson(type: EventType.membershipChanged);

  factory MembershipChangedEvent.fromJson(Map<String, dynamic> json) {
    return MembershipChangedEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'user_id': userId,
      'action': action,
    };
  }

  @override
  MembershipChangedEvent copyWith({
    String? chatId,
    String? userId,
    String? action,
    DateTime? timestamp,
    bool? processed,
  }) {
    return MembershipChangedEvent(
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      action: action ?? this.action,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// A co-member registered their per-chat public key for the first time
/// (NULL→value). Broadcast to the OTHER members so a sender can refresh and send
/// without reloading right after adding/scanning a peer (#116).
class MemberKeyRegisteredEvent extends BusEvent {
  final String chatId;
  final String userId;

  MemberKeyRegisteredEvent({
    required this.chatId,
    required this.userId,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.memberKeyRegistered,
          timestamp: timestamp ?? DateTime.now(),
        );

  MemberKeyRegisteredEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        userId = json['user_id'] as String,
        super._fromJson(type: EventType.memberKeyRegistered);

  factory MemberKeyRegisteredEvent.fromJson(Map<String, dynamic> json) {
    return MemberKeyRegisteredEvent._fromJson(json);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'user_id': userId,
    };
  }

  @override
  MemberKeyRegisteredEvent copyWith({
    String? chatId,
    String? userId,
    DateTime? timestamp,
    bool? processed,
  }) {
    return MemberKeyRegisteredEvent(
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Reaction added/removed on a message (broadcast to all chat members).
class ReactionChangedEvent extends BusEvent {
  final String chatId;
  final String messageId;
  final String userId;
  final String reaction;
  final String action; // 'added' | 'removed'

  ReactionChangedEvent({
    required this.chatId,
    required this.messageId,
    required this.userId,
    required this.reaction,
    required this.action,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.reactionChanged,
          timestamp: timestamp ?? DateTime.now(),
        );

  ReactionChangedEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        messageId = json['message_id'] as String,
        userId = json['user_id'] as String,
        reaction = json['reaction'] as String,
        action = json['action'] as String,
        super._fromJson(type: EventType.reactionChanged);

  factory ReactionChangedEvent.fromJson(Map<String, dynamic> json) {
    return ReactionChangedEvent._fromJson(json);
  }

  bool get isAdded => action == 'added';

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'chat_id': chatId,
      'message_id': messageId,
      'user_id': userId,
      'reaction': reaction,
      'action': action,
    };
  }

  @override
  ReactionChangedEvent copyWith({
    String? chatId,
    String? messageId,
    String? userId,
    String? reaction,
    String? action,
    DateTime? timestamp,
    bool? processed,
  }) {
    return ReactionChangedEvent(
      chatId: chatId ?? this.chatId,
      messageId: messageId ?? this.messageId,
      userId: userId ?? this.userId,
      reaction: reaction ?? this.reaction,
      action: action ?? this.action,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// A user's profile was updated or deleted (broadcast to chat co-members).
class ProfileChangedEvent extends BusEvent {
  final String userId;
  final String? username;
  final String action; // 'updated' | 'deleted'

  ProfileChangedEvent({
    required this.userId,
    required this.username,
    required this.action,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.profileChanged,
          timestamp: timestamp ?? DateTime.now(),
        );

  ProfileChangedEvent._fromJson(super.json)
      : userId = json['user_id'] as String,
        username = json['username'] as String?,
        action = json['action'] as String,
        super._fromJson(type: EventType.profileChanged);

  factory ProfileChangedEvent.fromJson(Map<String, dynamic> json) {
    return ProfileChangedEvent._fromJson(json);
  }

  bool get isDeleted => action == 'deleted';

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'user_id': userId,
      'username': username,
      'action': action,
    };
  }

  @override
  ProfileChangedEvent copyWith({
    String? userId,
    String? username,
    String? action,
    DateTime? timestamp,
    bool? processed,
  }) {
    return ProfileChangedEvent(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      action: action ?? this.action,
      timestamp: timestamp ?? this.timestamp,
      processed: processed ?? this.processed,
    );
  }
}

/// Somebody wants a 1:1 chat with you (migration 00082).
///
/// Deliberately carries NO id — who made the request is fetched by the client
/// from `my_incoming_chat_requests()`. The wake-up travels over the same
/// channel as the push, and that is the only one a third party reads along on.
class ChatRequestEvent extends BusEvent {
  ChatRequestEvent({DateTime? timestamp, super.processed})
      : super(
          type: EventType.chatRequest,
          timestamp: timestamp ?? DateTime.now(),
        );

  ChatRequestEvent._fromJson(super.json)
      : super._fromJson(type: EventType.chatRequest);

  factory ChatRequestEvent.fromJson(Map<String, dynamic> json) =>
      ChatRequestEvent._fromJson(json);

  @override
  ChatRequestEvent copyWith({DateTime? timestamp, bool? processed}) =>
      ChatRequestEvent(
        timestamp: timestamp ?? this.timestamp,
        processed: processed ?? this.processed,
      );
}

/// A sealed call signal from the peer of a 1:1 chat (migration 00085).
///
/// [senderId] comes from the server (`auth.uid()` of whoever called
/// `send_call_signal`), not from inside the envelope — and the envelope's AAD
/// and signature are bound to it, so a forged sender fails to open. The
/// content (offer/answer/ICE/end) is only readable after decrypting
/// [envelope]; the server never sees it.
class CallSignalEvent extends BusEvent {
  final String chatId;
  final String senderId;
  final String signalId;
  final String envelope;

  CallSignalEvent({
    required this.chatId,
    required this.senderId,
    required this.signalId,
    required this.envelope,
    DateTime? timestamp,
    super.processed,
  }) : super(
          type: EventType.callSignal,
          timestamp: timestamp ?? DateTime.now(),
        );

  CallSignalEvent._fromJson(super.json)
      : chatId = json['chat_id'] as String,
        senderId = json['sender_id'] as String,
        signalId = json['signal_id'] as String,
        envelope = json['envelope'] as String,
        super._fromJson(type: EventType.callSignal);

  factory CallSignalEvent.fromJson(Map<String, dynamic> json) =>
      CallSignalEvent._fromJson(json);

  @override
  CallSignalEvent copyWith({DateTime? timestamp, bool? processed}) =>
      CallSignalEvent(
        chatId: chatId,
        senderId: senderId,
        signalId: signalId,
        envelope: envelope,
        timestamp: timestamp ?? this.timestamp,
        processed: processed ?? this.processed,
      );
}
