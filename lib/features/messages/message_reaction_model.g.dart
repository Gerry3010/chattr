// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message_reaction_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_MessageReactionModel _$MessageReactionModelFromJson(
  Map<String, dynamic> json,
) => _MessageReactionModel(
  id: json['id'] as String,
  messageId: json['message_id'] as String,
  userId: json['user_id'] as String,
  reaction: json['reaction'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$MessageReactionModelToJson(
  _MessageReactionModel instance,
) => <String, dynamic>{
  'id': instance.id,
  'message_id': instance.messageId,
  'user_id': instance.userId,
  'reaction': instance.reaction,
  'created_at': instance.createdAt.toIso8601String(),
};

_ReactionSummary _$ReactionSummaryFromJson(Map<String, dynamic> json) =>
    _ReactionSummary(
      reaction: json['reaction'] as String,
      count: (json['count'] as num).toInt(),
      userReacted: json['user_reacted'] as bool,
      userIds:
          (json['user_ids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
    );

Map<String, dynamic> _$ReactionSummaryToJson(_ReactionSummary instance) =>
    <String, dynamic>{
      'reaction': instance.reaction,
      'count': instance.count,
      'user_reacted': instance.userReacted,
      'user_ids': instance.userIds,
    };

_ReactionUser _$ReactionUserFromJson(Map<String, dynamic> json) =>
    _ReactionUser(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );

Map<String, dynamic> _$ReactionUserToJson(_ReactionUser instance) =>
    <String, dynamic>{
      'user_id': instance.userId,
      'username': instance.username,
      'created_at': instance.createdAt.toIso8601String(),
    };
