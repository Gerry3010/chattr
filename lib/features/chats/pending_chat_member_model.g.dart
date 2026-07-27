// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pending_chat_member_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_PendingChatMember _$PendingChatMemberFromJson(Map<String, dynamic> json) =>
    _PendingChatMember(
      chatId: json['chat_id'] as String,
      userId: json['user_id'] as String,
      publicKey: json['public_key'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      blockedAt: json['blocked_at'] == null
          ? null
          : DateTime.parse(json['blocked_at'] as String),
    );

Map<String, dynamic> _$PendingChatMemberToJson(_PendingChatMember instance) =>
    <String, dynamic>{
      'chat_id': instance.chatId,
      'user_id': instance.userId,
      'public_key': instance.publicKey,
      'created_at': instance.createdAt.toIso8601String(),
      'updated_at': instance.updatedAt.toIso8601String(),
      'blocked_at': instance.blockedAt?.toIso8601String(),
    };
