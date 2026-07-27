// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_model.dart';

class ProfilesRepository {
  final SupabaseClient client;

  static const String avatarBucket = 'avatars';

  ProfilesRepository(this.client);

  /// Public URL for an avatar object path (bucket is public). Null-safe.
  String? avatarUrl(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    return client.storage.from(avatarBucket).getPublicUrl(avatarPath);
  }

  /// Upload (or replace) the user's avatar and persist its path on the profile.
  /// Returns the stored object path. The user may only write under their own
  /// uid folder (enforced by storage RLS).
  Future<String> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExtension,
    String contentType = 'image/jpeg',
  }) async {
    final ext = fileExtension.replaceAll('.', '').toLowerCase();
    final path = '$userId/avatar.$ext';
    await client.storage.from(avatarBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    await client.from('profiles').update({'avatar_path': path}).eq('id', userId);
    return path;
  }

  /// Change the user's display name. The `notify_profile_change` DB trigger
  /// (migration 00011) broadcasts `profileChanged` to chat co-members, who
  /// refresh automatically — no extra client work needed. Usernames are not
  /// unique, so no collision check.
  Future<Profile> updateUsername({
    required String userId,
    required String username,
  }) async {
    final res = await client
        .from('profiles')
        .update({'username': username})
        .eq('id', userId)
        .select()
        .single();
    return Profile.fromJson(res);
  }

  /// Publish this user's long-term Ed25519 identity public key (base64) so
  /// co-members can pin it and verify per-chat keys / message signatures
  /// (audit P0-a). Self-only write, enforced by the profiles UPDATE RLS policy
  /// (`auth.uid() = id`). Idempotent — safe to call on every startup; only
  /// writes when the value actually differs to avoid needless broadcasts.
  Future<void> publishIdentityKey({
    required String userId,
    required String identityPublicKey,
  }) async {
    await client
        .from('profiles')
        .update({'identity_public_key': identityPublicKey})
        .eq('id', userId);
  }

  Future<Profile?> fetchProfile(String userId) async {
    final res = await client
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();

    if (res == null) return null;
    return Profile.fromJson(res);
  }

  Future<Map<String, Profile?>> fetchProfiles(List<String> userIds) async {
    final res = await client
        .from('profiles')
        .select()
        .inFilter('id', userIds);

    final profileMap = <String, Profile?>{};
    for (final row in res) {
      profileMap[row['id'] as String] = Profile.fromJson(row);
    }
    for (final userId in userIds) {
      if (!profileMap.containsKey(userId)) {
        profileMap[userId] = null;
      }
    }

    return profileMap;
  }

  Future<Profile> createProfile({
    required String userId,
    required String username,
  }) async {
    final res = await client
        .from('profiles')
        .insert({
          'id': userId,
          'username': username,
        })
        .select()
        .single();

    return Profile.fromJson(res);
  }
}
