// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'pending_chat_member_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PendingChatMember {

@JsonKey(name: 'chat_id') String get chatId;@JsonKey(name: 'user_id') String get userId;@JsonKey(name: 'public_key') String get publicKey;@JsonKey(name: 'created_at') DateTime get createdAt;@JsonKey(name: 'updated_at') DateTime get updatedAt;@JsonKey(name: 'blocked_at') DateTime? get blockedAt;
/// Create a copy of PendingChatMember
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PendingChatMemberCopyWith<PendingChatMember> get copyWith => _$PendingChatMemberCopyWithImpl<PendingChatMember>(this as PendingChatMember, _$identity);

  /// Serializes this PendingChatMember to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PendingChatMember&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.publicKey, publicKey) || other.publicKey == publicKey)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.blockedAt, blockedAt) || other.blockedAt == blockedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,userId,publicKey,createdAt,updatedAt,blockedAt);

@override
String toString() {
  return 'PendingChatMember(chatId: $chatId, userId: $userId, publicKey: $publicKey, createdAt: $createdAt, updatedAt: $updatedAt, blockedAt: $blockedAt)';
}


}

/// @nodoc
abstract mixin class $PendingChatMemberCopyWith<$Res>  {
  factory $PendingChatMemberCopyWith(PendingChatMember value, $Res Function(PendingChatMember) _then) = _$PendingChatMemberCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'chat_id') String chatId,@JsonKey(name: 'user_id') String userId,@JsonKey(name: 'public_key') String publicKey,@JsonKey(name: 'created_at') DateTime createdAt,@JsonKey(name: 'updated_at') DateTime updatedAt,@JsonKey(name: 'blocked_at') DateTime? blockedAt
});




}
/// @nodoc
class _$PendingChatMemberCopyWithImpl<$Res>
    implements $PendingChatMemberCopyWith<$Res> {
  _$PendingChatMemberCopyWithImpl(this._self, this._then);

  final PendingChatMember _self;
  final $Res Function(PendingChatMember) _then;

/// Create a copy of PendingChatMember
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? chatId = null,Object? userId = null,Object? publicKey = null,Object? createdAt = null,Object? updatedAt = null,Object? blockedAt = freezed,}) {
  return _then(_self.copyWith(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,publicKey: null == publicKey ? _self.publicKey : publicKey // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,blockedAt: freezed == blockedAt ? _self.blockedAt : blockedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [PendingChatMember].
extension PendingChatMemberPatterns on PendingChatMember {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PendingChatMember value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PendingChatMember() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PendingChatMember value)  $default,){
final _that = this;
switch (_that) {
case _PendingChatMember():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PendingChatMember value)?  $default,){
final _that = this;
switch (_that) {
case _PendingChatMember() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'chat_id')  String chatId, @JsonKey(name: 'user_id')  String userId, @JsonKey(name: 'public_key')  String publicKey, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'updated_at')  DateTime updatedAt, @JsonKey(name: 'blocked_at')  DateTime? blockedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PendingChatMember() when $default != null:
return $default(_that.chatId,_that.userId,_that.publicKey,_that.createdAt,_that.updatedAt,_that.blockedAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'chat_id')  String chatId, @JsonKey(name: 'user_id')  String userId, @JsonKey(name: 'public_key')  String publicKey, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'updated_at')  DateTime updatedAt, @JsonKey(name: 'blocked_at')  DateTime? blockedAt)  $default,) {final _that = this;
switch (_that) {
case _PendingChatMember():
return $default(_that.chatId,_that.userId,_that.publicKey,_that.createdAt,_that.updatedAt,_that.blockedAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'chat_id')  String chatId, @JsonKey(name: 'user_id')  String userId, @JsonKey(name: 'public_key')  String publicKey, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'updated_at')  DateTime updatedAt, @JsonKey(name: 'blocked_at')  DateTime? blockedAt)?  $default,) {final _that = this;
switch (_that) {
case _PendingChatMember() when $default != null:
return $default(_that.chatId,_that.userId,_that.publicKey,_that.createdAt,_that.updatedAt,_that.blockedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PendingChatMember extends PendingChatMember {
  const _PendingChatMember({@JsonKey(name: 'chat_id') required this.chatId, @JsonKey(name: 'user_id') required this.userId, @JsonKey(name: 'public_key') required this.publicKey, @JsonKey(name: 'created_at') required this.createdAt, @JsonKey(name: 'updated_at') required this.updatedAt, @JsonKey(name: 'blocked_at') this.blockedAt}): super._();
  factory _PendingChatMember.fromJson(Map<String, dynamic> json) => _$PendingChatMemberFromJson(json);

@override@JsonKey(name: 'chat_id') final  String chatId;
@override@JsonKey(name: 'user_id') final  String userId;
@override@JsonKey(name: 'public_key') final  String publicKey;
@override@JsonKey(name: 'created_at') final  DateTime createdAt;
@override@JsonKey(name: 'updated_at') final  DateTime updatedAt;
@override@JsonKey(name: 'blocked_at') final  DateTime? blockedAt;

/// Create a copy of PendingChatMember
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PendingChatMemberCopyWith<_PendingChatMember> get copyWith => __$PendingChatMemberCopyWithImpl<_PendingChatMember>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PendingChatMemberToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PendingChatMember&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.publicKey, publicKey) || other.publicKey == publicKey)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.blockedAt, blockedAt) || other.blockedAt == blockedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,userId,publicKey,createdAt,updatedAt,blockedAt);

@override
String toString() {
  return 'PendingChatMember(chatId: $chatId, userId: $userId, publicKey: $publicKey, createdAt: $createdAt, updatedAt: $updatedAt, blockedAt: $blockedAt)';
}


}

/// @nodoc
abstract mixin class _$PendingChatMemberCopyWith<$Res> implements $PendingChatMemberCopyWith<$Res> {
  factory _$PendingChatMemberCopyWith(_PendingChatMember value, $Res Function(_PendingChatMember) _then) = __$PendingChatMemberCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'chat_id') String chatId,@JsonKey(name: 'user_id') String userId,@JsonKey(name: 'public_key') String publicKey,@JsonKey(name: 'created_at') DateTime createdAt,@JsonKey(name: 'updated_at') DateTime updatedAt,@JsonKey(name: 'blocked_at') DateTime? blockedAt
});




}
/// @nodoc
class __$PendingChatMemberCopyWithImpl<$Res>
    implements _$PendingChatMemberCopyWith<$Res> {
  __$PendingChatMemberCopyWithImpl(this._self, this._then);

  final _PendingChatMember _self;
  final $Res Function(_PendingChatMember) _then;

/// Create a copy of PendingChatMember
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? userId = null,Object? publicKey = null,Object? createdAt = null,Object? updatedAt = null,Object? blockedAt = freezed,}) {
  return _then(_PendingChatMember(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,publicKey: null == publicKey ? _self.publicKey : publicKey // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,blockedAt: freezed == blockedAt ? _self.blockedAt : blockedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
