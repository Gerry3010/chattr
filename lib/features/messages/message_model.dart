// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert' show jsonDecode;

import 'package:chattr/core/models/datetime_map_converter.dart';
import 'package:chattr/core/models/optional.dart';
import 'package:chattr/core/utils/ttl_format.dart';
import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';

part 'message_model.g.dart';

const String systemId = 'system';

/// Severity of a system message, driving the chip's colour and icon.
///
/// System messages used to render as one undifferentiated grey pill, so "Gerry
/// joined" and "Gerry generated new keys" — a routine event and a security-
/// relevant one you are meant to verify — looked exactly alike. The state is
/// derived from the action (see [SystemMessage.state]), never sent over the
/// wire: severity is a presentation decision that each client build owns, so it
/// can be re-tuned without a server change.
enum SystemMessageState { info, success, warning, error }

/// Key under which a system message's [SystemMessageState] rides along on the
/// converted `chatview.Message`.
///
/// `chatview.Message.update` is an untyped metadata bag the package itself
/// never reads or renders, which makes it the cheap way to hand the custom
/// builder something the package's model has no field for — the alternative
/// would be re-looking-up the original message by id on every rebuild.
const String systemStateKey = 'system_state';

/// Key under which the warn-only trust marker travels in the same bag.
///
/// It must NOT be baked into `chatview.Message.message`: every structured
/// envelope — media, album, invite — is recognised by parsing that exact
/// string, so a prefix in front of the JSON made all of them fall through to a
/// plain text bubble showing raw JSON. (Shipped in 1.14.0, found on a real
/// device: only senders WITHOUT an identity key are affected, so no amount of
/// testing between signed devices would have surfaced it.)
const String sigStatusKey = 'sig_status';

/// Reads the trust marker back off a converted message; null when the sender's
/// signature checked out or the envelope predates signatures entirely.
String? sigStatusOf(chatview.Message message) {
  final raw = message.update?[sigStatusKey];
  return raw is String && raw.isNotEmpty ? raw : null;
}

/// Does this `sig_status` warrant a visible marker?
///
/// ONLY the two failure states do. The bag also carries `'valid'` — the
/// successful check — and a bubble that treated "not null" as "something is
/// wrong" put "authorship unverified" over every correctly signed media, album
/// and invite message. Prose never showed it because its rendering switch has a
/// default arm; the structured bubbles had none, so the bug hid behind the
/// message type. Whoever adds a third status has to come here and decide, which
/// is the point of naming the two instead of negating `valid`.
bool sigStatusWarns(String? status) =>
    status == 'invalid' || status == 'unsigned';

/// Does this content look like one of our JSON envelopes rather than prose?
///
/// Used to decide whether the trust marker may be prefixed to the text at all.
/// Deliberately structural instead of a list of known envelope types: a new
/// envelope must not silently reintroduce the raw-JSON bug just because nobody
/// remembered to add it here. Prose that happens to be a JSON object loses its
/// inline marker (it still gets the one drawn beside the bubble) — the safe
/// direction, since the opposite breaks rendering.
bool looksLikeEnvelope(String? content) {
  final text = content?.trim();
  if (text == null || !text.startsWith('{') || !text.endsWith('}')) {
    return false;
  }
  try {
    return jsonDecode(text) is Map;
  } catch (_) {
    return false;
  }
}

/// Reads the state back off a converted message; defaults to
/// [SystemMessageState.info] for anything that didn't carry one.
SystemMessageState systemStateOf(chatview.Message message) {
  final raw = message.update?[systemStateKey];
  if (raw is! String) return SystemMessageState.info;
  for (final s in SystemMessageState.values) {
    if (s.name == raw) return s;
  }
  return SystemMessageState.info;
}

enum MessageType {
  user, // Regular encrypted user message
  system,
  // Summary machinery (request/reply envelopes, features/summary/). Encrypted
  // like a user message but never shown as conversation; the server suppresses
  // push for it (migration 00068). Pre-1.13 clients don't know this value and
  // drop the row at parse time — which is exactly the behaviour machinery
  // should have on a client that can't render it.
  summary;

  factory MessageType.from(String type) {
    return values.firstWhere(
      (e) => e.name.toLowerCase() == type.toLowerCase(),
      orElse: () => throw Exception('Unknown message type: $type'),
    );
  }

  static MessageType? tryFrom(String? type) {
    if (type == null) {
      return null;
    }
    try {
      return MessageType.from(type);
    } catch (e) {
      return null;
    }
  }
}

/// Interface that all message types implement
abstract class MessageInterface {
  final String id;
  final String chatId;

  String get senderId; // Optional for system messages
  final String recipientId;
  final DateTime createdAt;
  final DateTime? updatedAt; // Timestamp of last update

  // Maps of userId -> timestamp for tracking read status across all recipients
  // Includes current user's status
  // When each recipient received the message
  final Map<String, DateTime?> receivedAt;
  final Map<String, DateTime?> readAt; // When each recipient read the message

  MessageType get messageType;

  String? get encryptedContent;

  String? get decryptedContent;

  /// Check if this is a system message
  bool get isSystemMessage => messageType == MessageType.system;

  /// Check if this is a user message
  bool get isUserMessage => messageType == MessageType.user;

  MessageInterface({
    required this.id,
    required this.chatId,
    required this.recipientId,
    required this.createdAt,
    this.updatedAt,
    String? senderId,
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
  }) : receivedAt = receivedAt ?? {},
       readAt = readAt ?? {};

  factory MessageInterface.fromJson(Map<String, dynamic> json) {
    final messageTypeStr = json['message_type'] as String?;
    final senderId = json['sender_id'] as String?;

    final messageType =
        MessageType.tryFrom(messageTypeStr) ??
        (senderId == systemId ? MessageType.system : MessageType.user);

    // If it's a system message, use SystemMessage instead
    if (messageType == MessageType.system) {
      return SystemMessage.fromJson(json);
    }

    return Message.fromJson(json);
  }

  Map<String, dynamic> toJson();

  MessageInterface withDecryptedContent(String plaintext);

  MessageInterface copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? recipientId,
    DateTime? createdAt,
    Optional<DateTime?>? updatedAt,
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
    Optional<String?>? encryptedContent,
    Optional<String?>? decryptedContent,
  });

  @override
  String toString({
    int indent = 0,
    int propIndent = 2,
    Iterable<String>? displayProperties,
  }) {
    final Map<String, dynamic> properties = {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'recipientId': recipientId,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'receivedAt': receivedAt,
      'readAt': readAt,
      'encryptedContent': encryptedContent,
      'decryptedContent': decryptedContent,
    };

    final String indentStr = ' ' * indent;
    final String propIndentStr = ' ' * propIndent;

    final displayProps = (displayProperties ?? properties.keys).toList(
      growable: false,
    );

    final propStr = kDebugMode
        ? displayProps.fold(
            '\n$indentStr',
            (previousValue, element) => [
              previousValue,
              propIndentStr,
              element,
              ': ',
              properties[element],
              '\n',
              indentStr,
            ].join(),
          )
        : displayProps.map((prop) => '$prop: ${properties[prop]}').join(', ');
    return 'Message($propStr)';
  }
}

/// Regular user message with encryption
@JsonSerializable(
  fieldRename: FieldRename.snake,
  converters: [DateTimeMapConverter()],
)
class Message extends MessageInterface {
  @override
  final String senderId;

  @override
  final String? encryptedContent; // RSA-encrypted content
  @override
  final MessageType messageType;

  // Transient field - not stored in database
  @override
  String? decryptedContent;

  // Reply fields
  final String? replyToMessageId;
  final String? replyToSenderId;
  final String? replyToSenderName;
  final String? replyToPreview; // Encrypted preview text

  // Transient field - decrypted reply preview
  String? decryptedReplyPreview;

  /// When this message self-destructs (disappearing messages). Null = never.
  final DateTime? expiresAt;

  /// When the sender last edited this message; null = never edited. This is
  /// the ONLY source for the "Edited" label — updated_at is bumped by a DB
  /// trigger on every row update (read/receive marks) and means nothing.
  final DateTime? editedAt;

  /// Identity-signature verification result computed at decrypt time (audit
  /// H1, warn-only): 'valid' | 'invalid' | null (unsigned legacy message or
  /// sender without a published identity key). Persisted inside the encrypted
  /// local blob like every other field.
  final String? sigStatus;

  /// Local-only (#4): message starred/favorited by the user. Lives in the
  /// encrypted local blob; also mirrored to an indexed `is_favorite` column so
  /// the favorites view can query without decrypting every row.
  @JsonKey(defaultValue: false)
  final bool isFavorite;

  Message({
    required super.id,
    required super.chatId,
    required this.senderId,
    required super.recipientId,
    this.encryptedContent,
    this.messageType = MessageType.user,
    required super.createdAt,
    super.updatedAt,
    super.receivedAt,
    super.readAt,
    this.decryptedContent,
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyToSenderName,
    this.replyToPreview,
    this.decryptedReplyPreview,
    this.expiresAt,
    this.editedAt,
    this.sigStatus,
    this.isFavorite = false,
  });

  @override
  factory Message.fromJson(Map<String, dynamic> json) {
    final messageTypeStr = json['message_type'] as String? ?? 'user';
    // 'summary' rides the same encrypted pipeline as 'user'; only 'system'
    // (and unknowns) must not land here.
    if (messageTypeStr != 'user' && messageTypeStr != 'summary') {
      throw Exception('Invalid message type: $messageTypeStr');
    }
    if (json['sender_id'] == null) {
      throw Exception('Sender ID is required for user messages');
    }
    return _$MessageFromJson(json);
  }

  @override
  Map<String, dynamic> toJson() => _$MessageToJson(this);

  /// Create copy with decrypted content
  @override
  Message withDecryptedContent(String content) =>
      copyWith(decryptedContent: Optional(content), encryptedContent: Optional.empty());

  /// Create copy with updated read status
  @override
  Message copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? recipientId,
    DateTime? createdAt,
    Optional<DateTime?>? updatedAt,
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
    Optional<String?>? encryptedContent,
    Optional<String?>? decryptedContent,
    Optional<String?>? replyToMessageId,
    Optional<String?>? replyToSenderId,
    Optional<String?>? replyToSenderName,
    Optional<String?>? replyToPreview,
    Optional<String?>? decryptedReplyPreview,
    Optional<DateTime?>? editedAt,
    Optional<String?>? sigStatus,
    bool? isFavorite,
  }) {
    return Message(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      messageType: messageType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt.get(this.updatedAt),
      receivedAt: receivedAt ?? this.receivedAt,
      readAt: readAt ?? this.readAt,
      encryptedContent: encryptedContent.get(this.encryptedContent),
      decryptedContent: decryptedContent.get(this.decryptedContent),
      replyToMessageId: replyToMessageId.get(this.replyToMessageId),
      replyToSenderId: replyToSenderId.get(this.replyToSenderId),
      replyToSenderName: replyToSenderName.get(this.replyToSenderName),
      replyToPreview: replyToPreview.get(this.replyToPreview),
      decryptedReplyPreview: decryptedReplyPreview.get(
          this.decryptedReplyPreview),
      expiresAt: expiresAt,
      editedAt: editedAt.get(this.editedAt),
      sigStatus: sigStatus.get(this.sigStatus),
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  chatview.Message toChatViewMessage({
    List<chatview.Reaction>? reactions,
    // Override for link-containing texts, which render via the custom
    // builder (chatview's text bubble hard-wires the AnyLinkPreview card,
    // the big empty white block).
    chatview.MessageType chatViewType = chatview.MessageType.text,
    // Reciprocal read-receipt privacy: when the local user has read receipts
    // OFF, never promote a bubble to "read" — cap it at "delivered" so others'
    // read state stays hidden. "Delivered" itself is always honoured.
    bool showReadReceipts = true,
  }) {
    chatview.MessageStatus status = chatview.MessageStatus.undelivered;

    final allReceived =
        receivedAt.isNotEmpty &&
        receivedAt.values.every((value) => value != null);
    if (allReceived) {
      status = chatview.MessageStatus.delivered;
    }
    if (showReadReceipts) {
      final allRead =
          readAt.isNotEmpty && readAt.values.every((value) => value != null);
      if (allRead) {
        status = chatview.MessageStatus.read;
      }
    }

    // Build reply message if available
    chatview.ReplyMessage? replyMessage;
    if (replyToMessageId != null && replyToMessageId!.isNotEmpty &&
        replyToSenderId != null && replyToSenderId!.isNotEmpty) {
      replyMessage = chatview.ReplyMessage(
        message: decryptedReplyPreview ?? 'chat_view.encrypted'.tr(),
        // replyBy must be a USER ID (the sender of this reply message):
        // chatview's ReplyMessageWidget calls getUserFromId(replyBy), which
        // THROWS on unknown ids — passing the sender's display name here
        // rendered every reply bubble as a red ErrorWidget.
        replyBy: senderId,
        // ID of the person who sent the original message
        replyTo: replyToSenderId!,
        messageType: chatview.MessageType.text,
        messageId: replyToMessageId!,
      );
    }

    return chatview.Message(
      id: id,
      // Warn-only trust markers (audit H1): neither ever drops a message, the
      // bubble just says what is known. Two DIFFERENT glyphs on purpose —
      // "signature is wrong" (possible forgery) and "there is no signature"
      // (sender's device cannot sign) are not the same claim, and using one
      // symbol for both teaches people to ignore both.
      //
      // The marker is prefixed to the TEXT only for prose. For a JSON envelope
      // (media, album, invite) it travels in `update` under [sigStatusKey]
      // instead and the bubble draws it beside the content — prefixing there
      // broke the parse that decides what the bubble even is.
      message: looksLikeEnvelope(decryptedContent)
          ? decryptedContent!
          : switch (sigStatus) {
              'invalid' => '⚠️ ${'chat_view.unverified_sender'.tr()}\n'
                  '${decryptedContent ?? 'chat_view.encrypted'.tr()}',
              'unsigned' => 'ⓘ ${'chat_view.unsigned_sender'.tr()}\n'
                  '${decryptedContent ?? 'chat_view.encrypted'.tr()}',
              _ => decryptedContent ?? 'chat_view.encrypted'.tr(),
            },
      // Our chatview fork converts to local time internally (24h) for bubble
      // times + date separators, so we hand it the raw (UTC) value.
      createdAt: createdAt,
      sentBy: senderId,
      messageType: chatViewType,
      status: status,
      // chatview shows an "Edited" label whenever its updatedAt is non-null —
      // feed it the explicit edit marker. (Inferring from updated_at vs
      // created_at was wrong: the DB bumps updated_at on every read/receive
      // mark, so resynced rows showed a false "Edited".)
      updatedAt: editedAt,
      replyMessage: replyMessage ?? const chatview.ReplyMessage(),
      // chatview's Reaction is a pair of PARALLEL lists: one emoji per
      // reacting user, with that user's id at the same index. The chip's
      // count/avatars and the "who reacted" sheet all read reactedUserIds —
      // an empty list rendered the sheet blank.
      reaction: reactions != null && reactions.isNotEmpty
          ? chatview.Reaction(
              reactions: reactions.expand((r) => r.reactions).toList(),
              reactedUserIds:
                  reactions.expand((r) => r.reactedUserIds).toList(),
            )
          : null,
      // Metadata bag the package never renders — see [sigStatusKey]. Set for
      // EVERY marked message, prose included, so a bubble can draw the marker
      // itself rather than relying on the text prefix.
      update: sigStatus == null ? null : {sigStatusKey: sigStatus},
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Message) return false;
    final otherMessage = other;
    return id == otherMessage.id &&
        chatId == otherMessage.chatId &&
        senderId == otherMessage.senderId &&
        recipientId == otherMessage.recipientId &&
        createdAt == otherMessage.createdAt &&
        updatedAt == otherMessage.updatedAt &&
        receivedAt == otherMessage.receivedAt &&
        readAt == otherMessage.readAt &&
        encryptedContent == otherMessage.encryptedContent &&
        decryptedContent == otherMessage.decryptedContent &&
        editedAt == otherMessage.editedAt &&
        sigStatus == otherMessage.sigStatus;
  }

  @override
  int get hashCode {
    return Object.hashAll([
      id,
      chatId,
      senderId,
      recipientId,
      createdAt,
      updatedAt,
      receivedAt,
      readAt,
      encryptedContent,
      decryptedContent,
      editedAt,
      sigStatus,
    ]);
  }
}

/// System message (e.g., "User joined", "User left")
@JsonSerializable(
  fieldRename: FieldRename.snake,
  converters: [DateTimeMapConverter()],
)
class SystemMessage extends MessageInterface {
  @override
  final String? encryptedContent;
  @override
  String? decryptedContent;
  final String? action; // Action type (e.g., 'joined', 'left', 'approved')
  final String? subjectId; // ID of the user who is subject of the message
  final String? subjectName; // Name of the user who is subject of the message

  /// Free-form second argument for actions that need more than a subject —
  /// currently the TTL in seconds for `ttl_enabled`. Kept raw (not a rendered
  /// string) so every device formats it in its own locale.
  final String? detail;

  @override
  MessageType get messageType => MessageType.system;

  @override
  String get senderId => systemId;

  SystemMessage({
    required super.id,
    required super.chatId,
    required super.createdAt,
    super.updatedAt,
    super.receivedAt,
    super.readAt,
    required super.recipientId,
    this.encryptedContent,
    this.decryptedContent,
    this.action,
    this.subjectId,
    this.subjectName,
    this.detail,
  });

  factory SystemMessage.fromJson(Map<String, dynamic> json) =>
      _$SystemMessageFromJson(json);

  // senderId + messageType are constant getters (not stored fields), so they
  // aren't emitted by the generated toJson — add them back for the dispatch.
  @override
  Map<String, dynamic> toJson() => {
        ..._$SystemMessageToJson(this),
        'sender_id': senderId,
        'message_type': messageType.name,
      };

  /// Create copy with decrypted content
  /// Content should be JSON structure: {action, subject_id, subject_name}
  @override
  SystemMessage withDecryptedContent(String content, {String? action}) {
    String? parsedAction = action ?? this.action;
    String? parsedSubjectId = subjectId;
    String? parsedSubjectName = subjectName;
    String? parsedDetail = detail;

    // Parse JSON structure from decrypted content
    if (content.startsWith('{') && content.endsWith('}')) {
      try {
        final json = jsonDecode(content);
        parsedAction = json['action'] as String?;
        parsedSubjectId = json['subject_id'] as String?;
        parsedSubjectName = json['subject_name'] as String?;
        // Optional; only actions that need a second argument carry it. Read
        // loosely (the server sends the TTL as a number, older payloads omit
        // the key entirely) — an unexpected type must not lose the message.
        parsedDetail = json['detail']?.toString();
        // Store the original JSON as decrypted content for debugging
        content = json.toString();
      } catch (e) {
        // If parsing fails, keep original content
      }
    }

    return copyWith(
      decryptedContent: Optional.ofNullable(content),
      action: Optional.orNull(parsedAction),
      subjectId: Optional.orNull(parsedSubjectId),
      subjectName: Optional.orNull(parsedSubjectName),
      detail: Optional.orNull(parsedDetail),
      encryptedContent: Optional.empty(),
    );
  }

  @override
  SystemMessage copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? recipientId,
    DateTime? createdAt,
    Optional<DateTime?>? updatedAt,
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
    Optional<String?>? encryptedContent,
    Optional<String?>? decryptedContent,
    Optional<String?>? action,
    Optional<String?>? subjectId,
    Optional<String?>? subjectName,
    Optional<String?>? detail,
  }) {
    return SystemMessage(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      recipientId: recipientId ?? this.recipientId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt.get(this.updatedAt),
      receivedAt: receivedAt ?? this.receivedAt,
      readAt: readAt ?? this.readAt,
      encryptedContent: encryptedContent.get(this.encryptedContent),
      decryptedContent: decryptedContent.get(this.decryptedContent),
      action: action.get(this.action),
      subjectId: subjectId.get(this.subjectId),
      subjectName: subjectName.get(this.subjectName),
      detail: detail.get(this.detail),
    );
  }

  /// Human-readable text for this system message ("X ist beigetreten", ...).
  /// Requires [action]/[subjectName] to be populated — i.e. this message went
  /// through [withDecryptedContent], not just a raw `decryptedContent` set.
  /// Every live-event consumer (UI state, notification banners) MUST call
  /// withDecryptedContent(event.content) before reading this, or `action`
  /// stays null and this falls through to printing the raw {"action":...}
  /// JSON — the bug that made system messages show up unformatted while a
  /// chat was open live, even though a reload (which re-reads the correctly
  /// parsed copy already saved to local storage) looked fine.
  String get formattedText {
    final subject = subjectName ?? 'chat_detail.unknown_user'.tr();

    switch (action) {
      case 'joined':
        return 'system_messages.member_joined'.tr(args: [subject]);
      case 'left':
        return 'system_messages.member_left'.tr(args: [subject]);
      case 'removed': // admin kick (distinguished server-side since 00033)
        return 'system_messages.member_removed'.tr(args: [subject]);
      case 'promoted':
        return 'system_messages.member_promoted'.tr(args: [subject]);
      case 'approved':
        return 'system_messages.member_approved'.tr(args: [subject]);
      case 'keys_rotated':
        return 'system_messages.keys_rotated'.tr(args: [subject]);
      case 'ttl_enabled':
        // `detail` is the TTL in seconds; formatted locally so every device
        // reads it in its own locale.
        final seconds = int.tryParse(detail ?? '');
        if (seconds == null) {
          return 'system_messages.ttl_enabled_unknown'.tr(args: [subject]);
        }
        return 'system_messages.ttl_enabled'
            .tr(args: [subject, formatMessageTtl(seconds)]);
      case 'ttl_disabled':
        return 'system_messages.ttl_disabled'.tr(args: [subject]);
      case null:
        // Legacy plain-text system message (the pre-JSON client-side service)
        // or one whose ciphertext we could not decrypt.
        return decryptedContent ?? 'system_messages.undecryptable'.tr();
      default:
        // An action a newer server emits that this build doesn't know. The old
        // fallback printed `decryptedContent`, which for a JSON payload is the
        // raw `{action: …, subject_id: …}` map — worse than saying nothing.
        return 'system_messages.unsupported'.tr();
    }
  }

  /// Severity used to colour the chip. Derived from [action], not transmitted.
  SystemMessageState get state {
    switch (action) {
      // Somebody gained access — the group grew as intended.
      case 'joined':
      case 'approved':
        return SystemMessageState.success;
      // Enabling disappearing messages tightens privacy.
      case 'ttl_enabled':
        return SystemMessageState.success;
      // Neutral bookkeeping.
      case 'left':
      case 'promoted':
      case 'demoted':
      case 'chat_created':
        return SystemMessageState.info;
      // Worth a second look: a kick, a key change you should verify out of
      // band, or protection that was switched back off.
      case 'removed':
      case 'keys_rotated':
      case 'ttl_disabled':
        return SystemMessageState.warning;
      case null:
        // No action AND no plaintext = the payload never decrypted. That is a
        // real failure, not a neutral notice, so it earns the error colour.
        return decryptedContent == null
            ? SystemMessageState.error
            : SystemMessageState.info;
      default:
        return SystemMessageState.info;
    }
  }
}
