// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'profile_model.dart';
import 'profiles_controller.dart';

/// Helper provider to get a single profile by ID
///
/// Usage in widgets:
/// ```dart
/// final profile = ref.watch(profileProvider('user-id'));
/// ```
///
/// Returns null if profile is not loaded yet.
/// Automatically loads the profile if not cached.
final profileProvider = Provider.autoDispose.family<Profile?, String>((
  ref,
  userId,
) {
  final profilesController = ref.watch(profilesControllerProvider.notifier);
  final profiles = ref.watch(profilesControllerProvider);

  // Load profile if not cached (fire and forget)
  if (!profiles.containsKey(userId)) {
    // Schedule load for next frame to avoid calling during build
    Future.microtask(() => profilesController.loadProfile(userId));
  }

  return profiles[userId];
});

/// Helper provider to get multiple profiles by IDs
/// If a profile is not loaded yet, it will be loaded automatically.
/// If a profile does not exist or the requesting user isn't allowed to view it,
/// it will return a non-existent profile. See: [Profile.nonExistent].
///
/// Usage in widgets:
/// ```dart
/// final profiles = ref.watch(profilesListProvider(['user-1', 'user-2']));
/// ```
final profilesListProvider = Provider.autoDispose
    .family<List<Profile>, List<String>>((ref, userIds) {
      final profilesController = ref.watch(profilesControllerProvider.notifier);
      final profiles = ref.watch(profilesControllerProvider);

      // Load missing profiles
      final uncachedIds = userIds
          .where((id) => !profiles.containsKey(id))
          .toList();
      if (uncachedIds.isNotEmpty) {
        Future.microtask(() => profilesController.loadProfiles(uncachedIds));
      }

      // Return loaded profiles (may be incomplete initially)
      return userIds
          // Check if profile is cached; either loaded or non-existent
          .where((id) => profilesController.isProfileCached(id))
          .map((id) => profiles[id] ?? Profile.nonExistent(id))
          .toList();
    });

/// Get a nullable map of profiles by IDs
/// If a profile is not loaded yet, it will be loaded automatically.
/// If a profile does not exist or the requesting user isn't allowed to view it,
/// it will return null.
///
/// Usage in widgets:
/// ```dart
/// final profiles = ref.watch(profilesMapProvider({'user-1': 'user-2'}));
///
/// final profile1 = profiles['user-1'];
/// final profile2 = profiles['user-2'];
/// ```
final profilesMapProvider = Provider.autoDispose
    .family<
      Map<String, Profile?>,
      ({List<String> userIds, bool withEmptyProfiles})
    >((ref, params) {
      final userIds = params.userIds;
      final withNonExistent = params.withEmptyProfiles;
      final profilesController = ref.watch(profilesControllerProvider.notifier);
      final profiles = ref.watch(profilesControllerProvider);

      // Load missing profiles
      final uncachedIds = userIds
          .where((id) => !profiles.containsKey(id))
          .toList();
      if (uncachedIds.isNotEmpty) {
        Future.microtask(() => profilesController.loadProfiles(uncachedIds));
      }

      Profile? mapProfile(String userId) => profilesController.getCachedProfile(
        userId,
        returnNonExistent: withNonExistent,
      );
      // Return loaded profiles (may be incomplete initially)
      return {for (final id in userIds) id: mapProfile(id)};
    });

/// Helper to get username for a user ID
///
/// Returns "Loading..." if profile is not loaded yet
final usernameProvider = Provider.autoDispose.family<String, String>((
  ref,
  userId,
) {
  final profile = ref.watch(profileProvider(userId));
  return profile?.username ?? 'common.loading'.tr();
});

/// Helper to get an optional username for a user ID
/// Returns null if profile is not loaded yet
final optionalUsernameProvider = Provider.autoDispose.family<String?, String>((
  ref,
  userId,
) {
  final profile = ref.watch(profileProvider(userId));
  return profile?.username;
});
