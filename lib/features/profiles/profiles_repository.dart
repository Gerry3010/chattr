// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/logger_service.dart';
import '../media/image_metadata.dart';
import 'profile_model.dart';

class ProfilesRepository {
  final SupabaseClient client;

  static const String avatarBucket = 'avatars';

  ProfilesRepository(this.client);

  // There is deliberately no `avatarUrl` here any more. The bucket is private
  // (00075), so a public URL would simply 404 — an avatar is reached through a
  // short-lived signed URL from `avatarSignedUrlProvider`.

  /// Upload a new avatar for the user, point the profile at it and delete the
  /// one it replaces. Returns the stored object path. The user may only write
  /// under their own uid folder (enforced by storage RLS).
  ///
  /// EXIF/GPS is stripped here, at the choke point, rather than in the callers:
  /// chat media has gone through [ImageMetadata.normalizeAndStrip] since the L6
  /// audit fix, but avatars did NOT — they were uploaded raw into a **public**
  /// bucket, carrying GPS coordinates, device model and capture time. Doing it
  /// in the repository means every present and future caller is covered.
  Future<String> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExtension,
    String contentType = 'image/jpeg',
  }) async {
    final ext = fileExtension.replaceAll('.', '').toLowerCase();
    // A fresh name per upload (CHAT-23). The old fixed `<uid>/avatar.<ext>`
    // could be guessed by anyone who knew a uid, and since every image cache
    // keys on `bucket/path`, a new picture under the same name kept showing
    // the old one on other devices.
    final path = '$userId/${const Uuid().v4()}.$ext';
    final clean = await ImageMetadata.normalizeAndStrip(bytes, contentType);
    final previous = await _currentAvatarPath(userId);
    await client.storage.from(avatarBucket).uploadBinary(
          path,
          clean,
          fileOptions: FileOptions(contentType: contentType),
        );
    await client.from('profiles').update({'avatar_path': path}).eq('id', userId);
    await _removeReplacedAvatar(avatarBucket, previous, path, folder: userId);
    return path;
  }

  Future<String?> _currentAvatarPath(String userId) async {
    try {
      final row = await client
          .from('profiles')
          .select('avatar_path')
          .eq('id', userId)
          .maybeSingle();
      return row?['avatar_path'] as String?;
    } catch (_) {
      return null; // nothing to clean up is the safe answer
    }
  }

  /// Deletes the picture [next] replaced, once the profile points at [next].
  /// Best effort: a leftover only costs storage, and delete-account clears
  /// the whole folder anyway. Never touches anything outside [folder].
  Future<void> _removeReplacedAvatar(
    String bucket,
    String? previous,
    String next, {
    required String folder,
  }) async {
    if (previous == null || previous == next) return;
    if (!previous.startsWith('$folder/')) return;
    try {
      await client.storage.from(bucket).remove([previous]);
    } catch (e) {
      logger.warning('Could not remove replaced avatar $previous: $e',
          tag: 'ProfilesRepository');
    }
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
