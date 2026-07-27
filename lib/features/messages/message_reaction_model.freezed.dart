// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'message_reaction_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$MessageReactionModel {

 String get id;@JsonKey(name: 'message_id') String get messageId;@JsonKey(name: 'user_id') String get userId; String get reaction;@JsonKey(name: 'created_at') DateTime get createdAt;
/// Create a copy of MessageReactionModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessageReactionModelCopyWith<MessageReactionModel> get copyWith => _$MessageReactionModelCopyWithImpl<MessageReactionModel>(this as MessageReactionModel, _$identity);

  /// Serializes this MessageReactionModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessageReactionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.reaction, reaction) || other.reaction == reaction)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,messageId,userId,reaction,createdAt);

@override
String toString() {
  return 'MessageReactionModel(id: $id, messageId: $messageId, userId: $userId, reaction: $reaction, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $MessageReactionModelCopyWith<$Res>  {
  factory $MessageReactionModelCopyWith(MessageReactionModel value, $Res Function(MessageReactionModel) _then) = _$MessageReactionModelCopyWithImpl;
@useResult
$Res call({
 String id,@JsonKey(name: 'message_id') String messageId,@JsonKey(name: 'user_id') String userId, String reaction,@JsonKey(name: 'created_at') DateTime createdAt
});




}
/// @nodoc
class _$MessageReactionModelCopyWithImpl<$Res>
    implements $MessageReactionModelCopyWith<$Res> {
  _$MessageReactionModelCopyWithImpl(this._self, this._then);

  final MessageReactionModel _self;
  final $Res Function(MessageReactionModel) _then;

/// Create a copy of MessageReactionModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? messageId = null,Object? userId = null,Object? reaction = null,Object? createdAt = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,reaction: null == reaction ? _self.reaction : reaction // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [MessageReactionModel].
extension MessageReactionModelPatterns on MessageReactionModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _MessageReactionModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _MessageReactionModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _MessageReactionModel value)  $default,){
final _that = this;
switch (_that) {
case _MessageReactionModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _MessageReactionModel value)?  $default,){
final _that = this;
switch (_that) {
case _MessageReactionModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'message_id')  String messageId, @JsonKey(name: 'user_id')  String userId,  String reaction, @JsonKey(name: 'created_at')  DateTime createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _MessageReactionModel() when $default != null:
return $default(_that.id,_that.messageId,_that.userId,_that.reaction,_that.createdAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'message_id')  String messageId, @JsonKey(name: 'user_id')  String userId,  String reaction, @JsonKey(name: 'created_at')  DateTime createdAt)  $default,) {final _that = this;
switch (_that) {
case _MessageReactionModel():
return $default(_that.id,_that.messageId,_that.userId,_that.reaction,_that.createdAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id, @JsonKey(name: 'message_id')  String messageId, @JsonKey(name: 'user_id')  String userId,  String reaction, @JsonKey(name: 'created_at')  DateTime createdAt)?  $default,) {final _that = this;
switch (_that) {
case _MessageReactionModel() when $default != null:
return $default(_that.id,_that.messageId,_that.userId,_that.reaction,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _MessageReactionModel implements MessageReactionModel {
  const _MessageReactionModel({required this.id, @JsonKey(name: 'message_id') required this.messageId, @JsonKey(name: 'user_id') required this.userId, required this.reaction, @JsonKey(name: 'created_at') required this.createdAt});
  factory _MessageReactionModel.fromJson(Map<String, dynamic> json) => _$MessageReactionModelFromJson(json);

@override final  String id;
@override@JsonKey(name: 'message_id') final  String messageId;
@override@JsonKey(name: 'user_id') final  String userId;
@override final  String reaction;
@override@JsonKey(name: 'created_at') final  DateTime createdAt;

/// Create a copy of MessageReactionModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MessageReactionModelCopyWith<_MessageReactionModel> get copyWith => __$MessageReactionModelCopyWithImpl<_MessageReactionModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MessageReactionModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _MessageReactionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.reaction, reaction) || other.reaction == reaction)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,messageId,userId,reaction,createdAt);

@override
String toString() {
  return 'MessageReactionModel(id: $id, messageId: $messageId, userId: $userId, reaction: $reaction, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$MessageReactionModelCopyWith<$Res> implements $MessageReactionModelCopyWith<$Res> {
  factory _$MessageReactionModelCopyWith(_MessageReactionModel value, $Res Function(_MessageReactionModel) _then) = __$MessageReactionModelCopyWithImpl;
@override @useResult
$Res call({
 String id,@JsonKey(name: 'message_id') String messageId,@JsonKey(name: 'user_id') String userId, String reaction,@JsonKey(name: 'created_at') DateTime createdAt
});




}
/// @nodoc
class __$MessageReactionModelCopyWithImpl<$Res>
    implements _$MessageReactionModelCopyWith<$Res> {
  __$MessageReactionModelCopyWithImpl(this._self, this._then);

  final _MessageReactionModel _self;
  final $Res Function(_MessageReactionModel) _then;

/// Create a copy of MessageReactionModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? messageId = null,Object? userId = null,Object? reaction = null,Object? createdAt = null,}) {
  return _then(_MessageReactionModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,reaction: null == reaction ? _self.reaction : reaction // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}


/// @nodoc
mixin _$ReactionSummary {

 String get reaction; int get count;@JsonKey(name: 'user_reacted') bool get userReacted;// Who reacted (reaction order). chatview's "who reacted" sheet lists
// these ids; empty for payloads from a pre-00035 backend.
@JsonKey(name: 'user_ids') List<String> get userIds;
/// Create a copy of ReactionSummary
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ReactionSummaryCopyWith<ReactionSummary> get copyWith => _$ReactionSummaryCopyWithImpl<ReactionSummary>(this as ReactionSummary, _$identity);

  /// Serializes this ReactionSummary to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReactionSummary&&(identical(other.reaction, reaction) || other.reaction == reaction)&&(identical(other.count, count) || other.count == count)&&(identical(other.userReacted, userReacted) || other.userReacted == userReacted)&&const DeepCollectionEquality().equals(other.userIds, userIds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,reaction,count,userReacted,const DeepCollectionEquality().hash(userIds));

@override
String toString() {
  return 'ReactionSummary(reaction: $reaction, count: $count, userReacted: $userReacted, userIds: $userIds)';
}


}

/// @nodoc
abstract mixin class $ReactionSummaryCopyWith<$Res>  {
  factory $ReactionSummaryCopyWith(ReactionSummary value, $Res Function(ReactionSummary) _then) = _$ReactionSummaryCopyWithImpl;
@useResult
$Res call({
 String reaction, int count,@JsonKey(name: 'user_reacted') bool userReacted,@JsonKey(name: 'user_ids') List<String> userIds
});




}
/// @nodoc
class _$ReactionSummaryCopyWithImpl<$Res>
    implements $ReactionSummaryCopyWith<$Res> {
  _$ReactionSummaryCopyWithImpl(this._self, this._then);

  final ReactionSummary _self;
  final $Res Function(ReactionSummary) _then;

/// Create a copy of ReactionSummary
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? reaction = null,Object? count = null,Object? userReacted = null,Object? userIds = null,}) {
  return _then(_self.copyWith(
reaction: null == reaction ? _self.reaction : reaction // ignore: cast_nullable_to_non_nullable
as String,count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as int,userReacted: null == userReacted ? _self.userReacted : userReacted // ignore: cast_nullable_to_non_nullable
as bool,userIds: null == userIds ? _self.userIds : userIds // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [ReactionSummary].
extension ReactionSummaryPatterns on ReactionSummary {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ReactionSummary value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ReactionSummary() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ReactionSummary value)  $default,){
final _that = this;
switch (_that) {
case _ReactionSummary():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ReactionSummary value)?  $default,){
final _that = this;
switch (_that) {
case _ReactionSummary() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String reaction,  int count, @JsonKey(name: 'user_reacted')  bool userReacted, @JsonKey(name: 'user_ids')  List<String> userIds)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ReactionSummary() when $default != null:
return $default(_that.reaction,_that.count,_that.userReacted,_that.userIds);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String reaction,  int count, @JsonKey(name: 'user_reacted')  bool userReacted, @JsonKey(name: 'user_ids')  List<String> userIds)  $default,) {final _that = this;
switch (_that) {
case _ReactionSummary():
return $default(_that.reaction,_that.count,_that.userReacted,_that.userIds);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String reaction,  int count, @JsonKey(name: 'user_reacted')  bool userReacted, @JsonKey(name: 'user_ids')  List<String> userIds)?  $default,) {final _that = this;
switch (_that) {
case _ReactionSummary() when $default != null:
return $default(_that.reaction,_that.count,_that.userReacted,_that.userIds);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ReactionSummary implements ReactionSummary {
  const _ReactionSummary({required this.reaction, required this.count, @JsonKey(name: 'user_reacted') required this.userReacted, @JsonKey(name: 'user_ids') final  List<String> userIds = const <String>[]}): _userIds = userIds;
  factory _ReactionSummary.fromJson(Map<String, dynamic> json) => _$ReactionSummaryFromJson(json);

@override final  String reaction;
@override final  int count;
@override@JsonKey(name: 'user_reacted') final  bool userReacted;
// Who reacted (reaction order). chatview's "who reacted" sheet lists
// these ids; empty for payloads from a pre-00035 backend.
 final  List<String> _userIds;
// Who reacted (reaction order). chatview's "who reacted" sheet lists
// these ids; empty for payloads from a pre-00035 backend.
@override@JsonKey(name: 'user_ids') List<String> get userIds {
  if (_userIds is EqualUnmodifiableListView) return _userIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_userIds);
}


/// Create a copy of ReactionSummary
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ReactionSummaryCopyWith<_ReactionSummary> get copyWith => __$ReactionSummaryCopyWithImpl<_ReactionSummary>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ReactionSummaryToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ReactionSummary&&(identical(other.reaction, reaction) || other.reaction == reaction)&&(identical(other.count, count) || other.count == count)&&(identical(other.userReacted, userReacted) || other.userReacted == userReacted)&&const DeepCollectionEquality().equals(other._userIds, _userIds));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,reaction,count,userReacted,const DeepCollectionEquality().hash(_userIds));

@override
String toString() {
  return 'ReactionSummary(reaction: $reaction, count: $count, userReacted: $userReacted, userIds: $userIds)';
}


}

/// @nodoc
abstract mixin class _$ReactionSummaryCopyWith<$Res> implements $ReactionSummaryCopyWith<$Res> {
  factory _$ReactionSummaryCopyWith(_ReactionSummary value, $Res Function(_ReactionSummary) _then) = __$ReactionSummaryCopyWithImpl;
@override @useResult
$Res call({
 String reaction, int count,@JsonKey(name: 'user_reacted') bool userReacted,@JsonKey(name: 'user_ids') List<String> userIds
});




}
/// @nodoc
class __$ReactionSummaryCopyWithImpl<$Res>
    implements _$ReactionSummaryCopyWith<$Res> {
  __$ReactionSummaryCopyWithImpl(this._self, this._then);

  final _ReactionSummary _self;
  final $Res Function(_ReactionSummary) _then;

/// Create a copy of ReactionSummary
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? reaction = null,Object? count = null,Object? userReacted = null,Object? userIds = null,}) {
  return _then(_ReactionSummary(
reaction: null == reaction ? _self.reaction : reaction // ignore: cast_nullable_to_non_nullable
as String,count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as int,userReacted: null == userReacted ? _self.userReacted : userReacted // ignore: cast_nullable_to_non_nullable
as bool,userIds: null == userIds ? _self._userIds : userIds // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}


/// @nodoc
mixin _$ReactionUser {

@JsonKey(name: 'user_id') String get userId; String get username;@JsonKey(name: 'created_at') DateTime get createdAt;
/// Create a copy of ReactionUser
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ReactionUserCopyWith<ReactionUser> get copyWith => _$ReactionUserCopyWithImpl<ReactionUser>(this as ReactionUser, _$identity);

  /// Serializes this ReactionUser to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReactionUser&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.username, username) || other.username == username)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,username,createdAt);

@override
String toString() {
  return 'ReactionUser(userId: $userId, username: $username, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $ReactionUserCopyWith<$Res>  {
  factory $ReactionUserCopyWith(ReactionUser value, $Res Function(ReactionUser) _then) = _$ReactionUserCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'user_id') String userId, String username,@JsonKey(name: 'created_at') DateTime createdAt
});




}
/// @nodoc
class _$ReactionUserCopyWithImpl<$Res>
    implements $ReactionUserCopyWith<$Res> {
  _$ReactionUserCopyWithImpl(this._self, this._then);

  final ReactionUser _self;
  final $Res Function(ReactionUser) _then;

/// Create a copy of ReactionUser
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,Object? username = null,Object? createdAt = null,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}

}


/// Adds pattern-matching-related methods to [ReactionUser].
extension ReactionUserPatterns on ReactionUser {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ReactionUser value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ReactionUser() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ReactionUser value)  $default,){
final _that = this;
switch (_that) {
case _ReactionUser():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ReactionUser value)?  $default,){
final _that = this;
switch (_that) {
case _ReactionUser() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'user_id')  String userId,  String username, @JsonKey(name: 'created_at')  DateTime createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ReactionUser() when $default != null:
return $default(_that.userId,_that.username,_that.createdAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'user_id')  String userId,  String username, @JsonKey(name: 'created_at')  DateTime createdAt)  $default,) {final _that = this;
switch (_that) {
case _ReactionUser():
return $default(_that.userId,_that.username,_that.createdAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'user_id')  String userId,  String username, @JsonKey(name: 'created_at')  DateTime createdAt)?  $default,) {final _that = this;
switch (_that) {
case _ReactionUser() when $default != null:
return $default(_that.userId,_that.username,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ReactionUser implements ReactionUser {
  const _ReactionUser({@JsonKey(name: 'user_id') required this.userId, required this.username, @JsonKey(name: 'created_at') required this.createdAt});
  factory _ReactionUser.fromJson(Map<String, dynamic> json) => _$ReactionUserFromJson(json);

@override@JsonKey(name: 'user_id') final  String userId;
@override final  String username;
@override@JsonKey(name: 'created_at') final  DateTime createdAt;

/// Create a copy of ReactionUser
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ReactionUserCopyWith<_ReactionUser> get copyWith => __$ReactionUserCopyWithImpl<_ReactionUser>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ReactionUserToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ReactionUser&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.username, username) || other.username == username)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,username,createdAt);

@override
String toString() {
  return 'ReactionUser(userId: $userId, username: $username, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$ReactionUserCopyWith<$Res> implements $ReactionUserCopyWith<$Res> {
  factory _$ReactionUserCopyWith(_ReactionUser value, $Res Function(_ReactionUser) _then) = __$ReactionUserCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'user_id') String userId, String username,@JsonKey(name: 'created_at') DateTime createdAt
});




}
/// @nodoc
class __$ReactionUserCopyWithImpl<$Res>
    implements _$ReactionUserCopyWith<$Res> {
  __$ReactionUserCopyWithImpl(this._self, this._then);

  final _ReactionUser _self;
  final $Res Function(_ReactionUser) _then;

/// Create a copy of ReactionUser
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,Object? username = null,Object? createdAt = null,}) {
  return _then(_ReactionUser(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,
  ));
}


}

// dart format on
