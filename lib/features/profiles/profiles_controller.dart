// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_types.dart';
import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'profile_model.dart';
import 'profiles_repository.dart';

final profilesControllerProvider =
    StateNotifierProvider<ProfilesController, Map<String, Profile>>((ref) {
      final repo = ProfilesRepository(ref.read(supabaseClientProvider));
      return ProfilesController(ref, repo);
    });

class ProfilesController extends StateNotifier<Map<String, Profile>> {
  final _nonExistingIds = <String>{};

  final Ref _ref;
  final ProfilesRepository _profileRepo;
  StreamSubscription<BusEvent>? _eventSub;

  ProfilesController(this._ref, this._profileRepo) : super({}) {
    _init();
  }

  void _init() {
    // Profile changes now arrive on the single user event bus (profileChanged,
    // broadcast by the DB trigger to chat co-members) instead of a dedicated
    // `table-db-changes` Postgres-changes channel that was re-subscribed on
    // every profile load.
    final eventBus = _ref.read(eventBusProvider);
    _eventSub = eventBus?.eventStream.listen((event) {
      if (event is! ProfileChangedEvent) return;
      if (event.isDeleted) {
        final newState = Map<String, Profile>.from(state);
        newState.remove(event.userId);
        _nonExistingIds.add(event.userId);
        state = newState;
      } else if (state.containsKey(event.userId)) {
        // Refresh a profile we actually display.
        refreshProfile(event.userId);
      }
    });
  }

  /// Get a single profile by ID or fetch it.
  ///
  /// [forceRefresh] defaults to FALSE: historically it defaulted to true but
  /// was silently dropped on the way to [loadProfile], so every caller
  /// effectively got cache-first behaviour anyway. Passing the flag through
  /// while keeping the old default would have turned every cached read into a
  /// network call. Pass `forceRefresh: true` only where freshness genuinely
  /// matters (e.g. the verification screen re-checking a peer's identity key).
  Future<Profile?> getOptionalProfile(
    String userId, {
    bool forceRefresh = false,
  }) async {
    if (!isProfileCached(userId) || forceRefresh) {
      await loadProfile(userId, forceRefresh: forceRefresh);
    }
    return getCachedProfile(userId);
  }

  /// Get a single profile by ID or fetch it.
  /// If the profile doesn't exist, return a non-existent profile.
  /// See [getOptionalProfile] for the [forceRefresh] semantics.
  Future<Profile> getProfile(String userId, {bool forceRefresh = false}) async {
    final op = await getOptionalProfile(userId, forceRefresh: forceRefresh);
    return op ?? Profile.nonExistent(userId);
  }

  /// Load a single profile (only if not already cached)
  Future<void> loadProfile(String userId, {bool forceRefresh = false}) async {
    // Skip if already cached
    if (!forceRefresh && isProfileCached(userId)) {
      return;
    }

    final profile = await _profileRepo.fetchProfile(userId);
    if (profile != null) {
      state = {...state, profile.id: profile};
      _nonExistingIds.remove(profile.id);
    } else {
      state = Map.fromEntries(state.entries.where((e) => e.key != userId));
      _nonExistingIds.add(userId);
    }
  }

  /// Load multiple profiles at once (efficient batch loading)
  Future<void> loadProfiles(
    List<String> userIds, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      // Filter out already cached profiles
      userIds = userIds.where((id) => !isProfileCached(id)).toList();
    }

    if (userIds.isEmpty) {
      return; // All profiles already cached
    }

    final profiles = await _profileRepo.fetchProfiles(userIds);
    final newState = {...state};
    for (final profile in profiles.entries) {
      if (profile.value != null) {
        newState[profile.key] = profile.value!;
        _nonExistingIds.remove(profile.key);
      } else {
        newState.remove(profile.key);
        _nonExistingIds.add(profile.key);
      }
    }
    state = newState;
  }

  /// Get a profile from cache (or return null if not loaded)
  Profile? getCachedProfile(String userId, {bool returnNonExistent = false}) {
    if (state.containsKey(userId)) {
      return state[userId];
    } else if (returnNonExistent && _nonExistingIds.contains(userId)) {
      return Profile.nonExistent(userId);
    }
    return null;
  }

  /// Check if a profile is cached
  bool isProfileCached(String userId) {
    return state.containsKey(userId) || _nonExistingIds.contains(userId);
  }

  /// Force refresh a profile (ignores cache)
  Future<void> refreshProfile(String userId) async {
    final profile = await _profileRepo.fetchProfile(userId);
    if (profile != null) {
      state = {...state, profile.id: profile};
      _nonExistingIds.remove(profile.id);
    } else {
      state = Map<String, Profile>.fromEntries(
        state.entries.where((e) => e.key != userId),
      );
      _nonExistingIds.add(userId);
    }
  }

  // `avatarUrl` is gone: the bucket is private (00075). Watch
  // `avatarSignedUrlProvider((bucket: kAvatarBucket, path: …))` instead.

  /// Upload a new avatar for [userId] and update the cached profile.
  Future<void> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExtension,
    String contentType = 'image/jpeg',
  }) async {
    final path = await _profileRepo.uploadAvatar(
      userId: userId,
      bytes: bytes,
      fileExtension: fileExtension,
      contentType: contentType,
    );
    final current = state[userId];
    if (current != null) {
      state = {...state, userId: current.copyWith(avatarPath: path)};
    } else {
      await refreshProfile(userId);
    }
    logger.info('🖼️ Uploaded avatar for $userId → $path',
        tag: 'ProfilesController');
  }

  /// Change the user's display name and update the cached profile. Co-members
  /// are notified by the DB trigger (see ProfilesRepository.updateUsername).
  Future<void> updateUsername({
    required String userId,
    required String username,
  }) async {
    final profile = await _profileRepo.updateUsername(
      userId: userId,
      username: username,
    );
    state = {...state, userId: profile};
    logger.info('✏️ Updated username for $userId → $username',
        tag: 'ProfilesController');
  }

  /// Clear the entire cache
  void clearCache() {
    state = {};
    _nonExistingIds.clear();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
