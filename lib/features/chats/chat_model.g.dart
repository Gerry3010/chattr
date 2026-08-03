// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Chat _$ChatFromJson(Map<String, dynamic> json) => Chat(
  id: json['id'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  updatedAt: json['updated_at'] == null
      ? null
      : DateTime.parse(json['updated_at'] as String),
  insertedAt: json['inserted_at'] == null
      ? null
      : DateTime.parse(json['inserted_at'] as String),
  createdBy: json['created_by'] as String?,
  name: json['name'] as String?,
  description: json['description'] as String?,
  avatarPath: json['avatar_path'] as String?,
  admins:
      (json['admins'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  isGroup: json['is_group'] as bool? ?? true,
  lastMessageAt: json['last_message_at'] == null
      ? null
      : DateTime.parse(json['last_message_at'] as String),
  unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
  messageTtlSeconds: (json['message_ttl_seconds'] as num?)?.toInt(),
  isMcp: json['is_mcp'] as bool? ?? false,
  mcpOwnerId: json['mcp_owner_id'] as String?,
  isPinned: json['is_pinned'] as bool? ?? false,
);

Map<String, dynamic> _$ChatToJson(Chat instance) => <String, dynamic>{
  'id': instance.id,
  'created_at': instance.createdAt.toIso8601String(),
  'updated_at': instance.updatedAt.toIso8601String(),
  'inserted_at': instance.insertedAt.toIso8601String(),
  'created_by': instance.createdBy,
  'name': instance.name,
  'description': instance.description,
  'avatar_path': instance.avatarPath,
  'admins': instance.admins,
  'is_group': instance.isGroup,
  'last_message_at': instance.lastMessageAt?.toIso8601String(),
  'unread_count': instance.unreadCount,
  'message_ttl_seconds': instance.messageTtlSeconds,
  'is_mcp': instance.isMcp,
  'mcp_owner_id': instance.mcpOwnerId,
  'is_pinned': instance.isPinned,
};
