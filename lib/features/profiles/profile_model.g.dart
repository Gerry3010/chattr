// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'profile_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Profile _$ProfileFromJson(Map<String, dynamic> json) => _Profile(
  id: json['id'] as String,
  username: json['username'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  avatarPath: json['avatar_path'] as String?,
  identityPublicKey: json['identity_public_key'] as String?,
);

Map<String, dynamic> _$ProfileToJson(_Profile instance) => <String, dynamic>{
  'id': instance.id,
  'username': instance.username,
  'created_at': instance.createdAt.toIso8601String(),
  'avatar_path': instance.avatarPath,
  'identity_public_key': instance.identityPublicKey,
};
