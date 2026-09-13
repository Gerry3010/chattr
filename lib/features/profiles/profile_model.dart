// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile_model.freezed.dart';
part 'profile_model.g.dart';

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required String id,
    required String username,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'avatar_path') String? avatarPath,
    // Base64 Ed25519 long-term identity public key (audit P0-a). Null until the
    // peer's client has published it (older clients, or not yet synced).
    @JsonKey(name: 'identity_public_key') String? identityPublicKey,
    // Self-declared MCP-agent account (00068) — display-only grouping for the
    // agents section, no rights hang off it. Absent key (pre-migration
    // backend) parses as false.
    @JsonKey(name: 'is_agent') @Default(false) bool isAgent,
    // Transient: whether the profile exists on the server (not serialized).
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(true)
    bool exists,
  }) = _Profile;

  factory Profile.fromJson(Map<String, dynamic> json) =>
      _$ProfileFromJson(json);

  factory Profile.nonExistent(String id) => Profile(
        id: id,
        username: 'chat_detail.unknown_user'.tr(),
        createdAt: DateTime.now(),
        exists: false,
      );
}
