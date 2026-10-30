// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'profile_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Profile {

 String get id; String get username;@JsonKey(name: 'created_at') DateTime get createdAt;@JsonKey(name: 'avatar_path') String? get avatarPath;// Base64 Ed25519 long-term identity public key (audit P0-a). Null until the
// peer's client has published it (older clients, or not yet synced).
@JsonKey(name: 'identity_public_key') String? get identityPublicKey;// Self-declared MCP-agent account (00068) — display-only grouping for the
// agents section, no rights hang off it. Absent key (pre-migration
// backend) parses as false.
@JsonKey(name: 'is_agent') bool get isAgent;// Transient: whether the profile exists on the server (not serialized).
@JsonKey(includeFromJson: false, includeToJson: false) bool get exists;
/// Create a copy of Profile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProfileCopyWith<Profile> get copyWith => _$ProfileCopyWithImpl<Profile>(this as Profile, _$identity);

  /// Serializes this Profile to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Profile&&(identical(other.id, id) || other.id == id)&&(identical(other.username, username) || other.username == username)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.avatarPath, avatarPath) || other.avatarPath == avatarPath)&&(identical(other.identityPublicKey, identityPublicKey) || other.identityPublicKey == identityPublicKey)&&(identical(other.isAgent, isAgent) || other.isAgent == isAgent)&&(identical(other.exists, exists) || other.exists == exists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,username,createdAt,avatarPath,identityPublicKey,isAgent,exists);

@override
String toString() {
  return 'Profile(id: $id, username: $username, createdAt: $createdAt, avatarPath: $avatarPath, identityPublicKey: $identityPublicKey, isAgent: $isAgent, exists: $exists)';
}


}

/// @nodoc
abstract mixin class $ProfileCopyWith<$Res>  {
  factory $ProfileCopyWith(Profile value, $Res Function(Profile) _then) = _$ProfileCopyWithImpl;
@useResult
$Res call({
 String id, String username,@JsonKey(name: 'created_at') DateTime createdAt,@JsonKey(name: 'avatar_path') String? avatarPath,@JsonKey(name: 'identity_public_key') String? identityPublicKey,@JsonKey(name: 'is_agent') bool isAgent,@JsonKey(includeFromJson: false, includeToJson: false) bool exists
});




}
/// @nodoc
class _$ProfileCopyWithImpl<$Res>
    implements $ProfileCopyWith<$Res> {
  _$ProfileCopyWithImpl(this._self, this._then);

  final Profile _self;
  final $Res Function(Profile) _then;

/// Create a copy of Profile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? username = null,Object? createdAt = null,Object? avatarPath = freezed,Object? identityPublicKey = freezed,Object? isAgent = null,Object? exists = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,avatarPath: freezed == avatarPath ? _self.avatarPath : avatarPath // ignore: cast_nullable_to_non_nullable
as String?,identityPublicKey: freezed == identityPublicKey ? _self.identityPublicKey : identityPublicKey // ignore: cast_nullable_to_non_nullable
as String?,isAgent: null == isAgent ? _self.isAgent : isAgent // ignore: cast_nullable_to_non_nullable
as bool,exists: null == exists ? _self.exists : exists // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [Profile].
extension ProfilePatterns on Profile {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Profile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Profile() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Profile value)  $default,){
final _that = this;
switch (_that) {
case _Profile():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Profile value)?  $default,){
final _that = this;
switch (_that) {
case _Profile() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String username, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'avatar_path')  String? avatarPath, @JsonKey(name: 'identity_public_key')  String? identityPublicKey, @JsonKey(name: 'is_agent')  bool isAgent, @JsonKey(includeFromJson: false, includeToJson: false)  bool exists)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Profile() when $default != null:
return $default(_that.id,_that.username,_that.createdAt,_that.avatarPath,_that.identityPublicKey,_that.isAgent,_that.exists);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String username, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'avatar_path')  String? avatarPath, @JsonKey(name: 'identity_public_key')  String? identityPublicKey, @JsonKey(name: 'is_agent')  bool isAgent, @JsonKey(includeFromJson: false, includeToJson: false)  bool exists)  $default,) {final _that = this;
switch (_that) {
case _Profile():
return $default(_that.id,_that.username,_that.createdAt,_that.avatarPath,_that.identityPublicKey,_that.isAgent,_that.exists);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String username, @JsonKey(name: 'created_at')  DateTime createdAt, @JsonKey(name: 'avatar_path')  String? avatarPath, @JsonKey(name: 'identity_public_key')  String? identityPublicKey, @JsonKey(name: 'is_agent')  bool isAgent, @JsonKey(includeFromJson: false, includeToJson: false)  bool exists)?  $default,) {final _that = this;
switch (_that) {
case _Profile() when $default != null:
return $default(_that.id,_that.username,_that.createdAt,_that.avatarPath,_that.identityPublicKey,_that.isAgent,_that.exists);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Profile implements Profile {
  const _Profile({required this.id, required this.username, @JsonKey(name: 'created_at') required this.createdAt, @JsonKey(name: 'avatar_path') this.avatarPath, @JsonKey(name: 'identity_public_key') this.identityPublicKey, @JsonKey(name: 'is_agent') this.isAgent = false, @JsonKey(includeFromJson: false, includeToJson: false) this.exists = true});
  factory _Profile.fromJson(Map<String, dynamic> json) => _$ProfileFromJson(json);

@override final  String id;
@override final  String username;
@override@JsonKey(name: 'created_at') final  DateTime createdAt;
@override@JsonKey(name: 'avatar_path') final  String? avatarPath;
// Base64 Ed25519 long-term identity public key (audit P0-a). Null until the
// peer's client has published it (older clients, or not yet synced).
@override@JsonKey(name: 'identity_public_key') final  String? identityPublicKey;
// Self-declared MCP-agent account (00068) — display-only grouping for the
// agents section, no rights hang off it. Absent key (pre-migration
// backend) parses as false.
@override@JsonKey(name: 'is_agent') final  bool isAgent;
// Transient: whether the profile exists on the server (not serialized).
@override@JsonKey(includeFromJson: false, includeToJson: false) final  bool exists;

/// Create a copy of Profile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProfileCopyWith<_Profile> get copyWith => __$ProfileCopyWithImpl<_Profile>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ProfileToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Profile&&(identical(other.id, id) || other.id == id)&&(identical(other.username, username) || other.username == username)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.avatarPath, avatarPath) || other.avatarPath == avatarPath)&&(identical(other.identityPublicKey, identityPublicKey) || other.identityPublicKey == identityPublicKey)&&(identical(other.isAgent, isAgent) || other.isAgent == isAgent)&&(identical(other.exists, exists) || other.exists == exists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,username,createdAt,avatarPath,identityPublicKey,isAgent,exists);

@override
String toString() {
  return 'Profile(id: $id, username: $username, createdAt: $createdAt, avatarPath: $avatarPath, identityPublicKey: $identityPublicKey, isAgent: $isAgent, exists: $exists)';
}


}

/// @nodoc
abstract mixin class _$ProfileCopyWith<$Res> implements $ProfileCopyWith<$Res> {
  factory _$ProfileCopyWith(_Profile value, $Res Function(_Profile) _then) = __$ProfileCopyWithImpl;
@override @useResult
$Res call({
 String id, String username,@JsonKey(name: 'created_at') DateTime createdAt,@JsonKey(name: 'avatar_path') String? avatarPath,@JsonKey(name: 'identity_public_key') String? identityPublicKey,@JsonKey(name: 'is_agent') bool isAgent,@JsonKey(includeFromJson: false, includeToJson: false) bool exists
});




}
/// @nodoc
class __$ProfileCopyWithImpl<$Res>
    implements _$ProfileCopyWith<$Res> {
  __$ProfileCopyWithImpl(this._self, this._then);

  final _Profile _self;
  final $Res Function(_Profile) _then;

/// Create a copy of Profile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? username = null,Object? createdAt = null,Object? avatarPath = freezed,Object? identityPublicKey = freezed,Object? isAgent = null,Object? exists = null,}) {
  return _then(_Profile(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,avatarPath: freezed == avatarPath ? _self.avatarPath : avatarPath // ignore: cast_nullable_to_non_nullable
as String?,identityPublicKey: freezed == identityPublicKey ? _self.identityPublicKey : identityPublicKey // ignore: cast_nullable_to_non_nullable
as String?,isAgent: null == isAgent ? _self.isAgent : isAgent // ignore: cast_nullable_to_non_nullable
as bool,exists: null == exists ? _self.exists : exists // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
