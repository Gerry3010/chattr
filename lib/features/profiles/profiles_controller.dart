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
import '../chats/roster_store.dart';
import 'profile_model.dart';
import 'profiles_repository.dart';

final profilesControllerProvider =
    StateNotifierProvider<ProfilesController, Map<String, Profile>>((ref) {
      final repo = ProfilesRepository(ref.read(supabaseClientProvider));
      return ProfilesController(ref, repo);
    });

class ProfilesController extends StateNotifier<Map<String, Profile>> {
  final _nonExistingIds = <String>{};

  /// Profiles read from the device's roster (CHAT-62) and not yet confirmed by
  /// the server in this session. Good enough to show a name and a colour, not
  /// good enough to pin or compare an identity key: [getOptionalProfile] and
  /// the loaders treat them as missing and fetch.
  final _stale = <String>{};
  bool _refreshingStale = false;

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
        _stale.remove(event.userId);
        _forget([event.userId]);
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
    if (!_isFresh(userId) || forceRefresh) {
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
    if (!forceRefresh && _isFresh(userId)) {
      return;
    }

    final profile = await _profileRepo.fetchProfile(userId);
    _apply({userId: profile});
  }

  /// Load multiple profiles at once (efficient batch loading)
  Future<void> loadProfiles(
    List<String> userIds, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      // Filter out already cached profiles
      userIds = userIds.where((id) => !_isFresh(id)).toList();
    }

    if (userIds.isEmpty) {
      return; // All profiles already cached
    }

    _apply(await _profileRepo.fetchProfiles(userIds));
  }

  /// Take a server answer into the cache and onto the device. A null is an
  /// authoritative "gone or not visible to you", so it also drops the stored
  /// copy; a network error never gets here.
  void _apply(Map<String, Profile?> fetched) {
    if (fetched.isEmpty) return;
    final newState = {...state};
    final found = <Profile>[];
    final gone = <String>[];
    for (final entry in fetched.entries) {
      _stale.remove(entry.key);
      final profile = entry.value;
      if (profile != null) {
        newState[entry.key] = profile;
        _nonExistingIds.remove(entry.key);
        found.add(profile);
      } else {
        newState.remove(entry.key);
        _nonExistingIds.add(entry.key);
        gone.add(entry.key);
      }
    }
    state = newState;
    _remember(found);
    _forget(gone);
  }

  /// Fill the cache from the device's roster (CHAT-62), so names and colours
  /// are there before, or without, the first answer from the server. Only
  /// fills gaps; every entry stays stale until [refreshStale] confirms it.
  void hydrate(Map<String, Profile> stored) {
    final added = <String, Profile>{};
    for (final entry in stored.entries) {
      if (state.containsKey(entry.key) || _nonExistingIds.contains(entry.key)) {
        continue;
      }
      added[entry.key] = entry.value;
      _stale.add(entry.key);
    }
    if (added.isNotEmpty) state = {...state, ...added};
  }

  /// Confirm every stored profile with the server in one request. Called
  /// after each successful chat refresh; a no-op once nothing is stale. Does
  /// not throw: offline the stored names simply stay.
  Future<void> refreshStale() async {
    if (_stale.isEmpty || _refreshingStale) return;
    _refreshingStale = true;
    try {
      await loadProfiles(_stale.toList(), forceRefresh: true);
    } catch (e) {
      logger.debug('Stored profiles not confirmed yet: $e',
          tag: 'ProfilesController');
    } finally {
      _refreshingStale = false;
    }
  }

  bool _isFresh(String userId) =>
      isProfileCached(userId) && !_stale.contains(userId);

  RosterStore? get _store {
    try {
      return _ref.read(rosterStoreProvider);
    } catch (_) {
      return null;
    }
  }

  void _remember(List<Profile> profiles) {
    final store = _store;
    if (store == null || profiles.isEmpty) return;
    unawaited(store.saveProfiles(profiles).catchError((Object e) {
      logger.warning('Could not store profiles: $e', tag: 'ProfilesController');
    }));
  }

  void _forget(List<String> userIds) {
    final store = _store;
    if (store == null || userIds.isEmpty) return;
    unawaited(store.deleteProfiles(userIds).catchError((Object e) {
      logger.warning('Could not drop stored profiles: $e',
          tag: 'ProfilesController');
    }));
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
    _apply({userId: profile});
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
      final updated = current.copyWith(avatarPath: path);
      state = {...state, userId: updated};
      _remember([updated]);
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
    _stale.remove(userId);
    _remember([profile]);
    logger.info('✏️ Updated username for $userId → $username',
        tag: 'ProfilesController');
  }

  /// Clear the entire cache
  /// The stored roster is wiped separately, with the rest of the local data.
  void clearCache() {
    state = {};
    _nonExistingIds.clear();
    _stale.clear();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
