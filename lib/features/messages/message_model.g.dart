// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Message _$MessageFromJson(Map<String, dynamic> json) => Message(
  id: json['id'] as String,
  chatId: json['chat_id'] as String,
  senderId: json['sender_id'] as String,
  recipientId: json['recipient_id'] as String,
  encryptedContent: json['encrypted_content'] as String?,
  messageType:
      $enumDecodeNullable(_$MessageTypeEnumMap, json['message_type']) ??
      MessageType.user,
  createdAt: DateTime.parse(json['created_at'] as String),
  updatedAt: json['updated_at'] == null
      ? null
      : DateTime.parse(json['updated_at'] as String),
  receivedAt: const DateTimeMapConverter().fromJson(json['received_at']),
  readAt: const DateTimeMapConverter().fromJson(json['read_at']),
  decryptedContent: json['decrypted_content'] as String?,
  replyToMessageId: json['reply_to_message_id'] as String?,
  replyToSenderId: json['reply_to_sender_id'] as String?,
  replyToSenderName: json['reply_to_sender_name'] as String?,
  replyToPreview: json['reply_to_preview'] as String?,
  decryptedReplyPreview: json['decrypted_reply_preview'] as String?,
  expiresAt: json['expires_at'] == null
      ? null
      : DateTime.parse(json['expires_at'] as String),
  editedAt: json['edited_at'] == null
      ? null
      : DateTime.parse(json['edited_at'] as String),
  sigStatus: json['sig_status'] as String?,
  isFavorite: json['is_favorite'] as bool? ?? false,
);

Map<String, dynamic> _$MessageToJson(Message instance) => <String, dynamic>{
  'id': instance.id,
  'chat_id': instance.chatId,
  'recipient_id': instance.recipientId,
  'created_at': instance.createdAt.toIso8601String(),
  'updated_at': instance.updatedAt?.toIso8601String(),
  'received_at': const DateTimeMapConverter().toJson(instance.receivedAt),
  'read_at': const DateTimeMapConverter().toJson(instance.readAt),
  'sender_id': instance.senderId,
  'encrypted_content': instance.encryptedContent,
  'message_type': _$MessageTypeEnumMap[instance.messageType]!,
  'decrypted_content': instance.decryptedContent,
  'reply_to_message_id': instance.replyToMessageId,
  'reply_to_sender_id': instance.replyToSenderId,
  'reply_to_sender_name': instance.replyToSenderName,
  'reply_to_preview': instance.replyToPreview,
  'decrypted_reply_preview': instance.decryptedReplyPreview,
  'expires_at': instance.expiresAt?.toIso8601String(),
  'edited_at': instance.editedAt?.toIso8601String(),
  'sig_status': instance.sigStatus,
  'is_favorite': instance.isFavorite,
};

const _$MessageTypeEnumMap = {
  MessageType.user: 'user',
  MessageType.system: 'system',
};

SystemMessage _$SystemMessageFromJson(Map<String, dynamic> json) =>
    SystemMessage(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.parse(json['updated_at'] as String),
      receivedAt: const DateTimeMapConverter().fromJson(json['received_at']),
      readAt: const DateTimeMapConverter().fromJson(json['read_at']),
      recipientId: json['recipient_id'] as String,
      encryptedContent: json['encrypted_content'] as String?,
      decryptedContent: json['decrypted_content'] as String?,
      action: json['action'] as String?,
      subjectId: json['subject_id'] as String?,
      subjectName: json['subject_name'] as String?,
      detail: json['detail'] as String?,
    );

Map<String, dynamic> _$SystemMessageToJson(SystemMessage instance) =>
    <String, dynamic>{
      'id': instance.id,
      'chat_id': instance.chatId,
      'recipient_id': instance.recipientId,
      'created_at': instance.createdAt.toIso8601String(),
      'updated_at': instance.updatedAt?.toIso8601String(),
      'received_at': const DateTimeMapConverter().toJson(instance.receivedAt),
      'read_at': const DateTimeMapConverter().toJson(instance.readAt),
      'encrypted_content': instance.encryptedContent,
      'decrypted_content': instance.decryptedContent,
      'action': instance.action,
      'subject_id': instance.subjectId,
      'subject_name': instance.subjectName,
      'detail': instance.detail,
    };
