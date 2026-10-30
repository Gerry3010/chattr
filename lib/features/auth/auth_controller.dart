// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../../core/init/app_init.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../profiles/profiles_repository.dart';
import '../profiles/profiles_controller.dart';
import '../chats/chats_controller.dart';
import '../chats/chats_local_provider.dart';
import '../chats/roster_store.dart';
import '../messages/messages_local_provider.dart';
import '../push_notifications/push_notifications_provider.dart';
import '../share_suggestions/share_suggestions_channel.dart';
import '../recovery/recovery_service.dart';
import '../recovery/recovery_key_reconciler.dart';
import 'auth_repository.dart';

final authControllerProvider =
    StateNotifierProvider<AuthController, String?>((ref) {
  final authRepo = AuthRepository(ref.read(supabaseClientProvider));
  final profilesRepo = ProfilesRepository(ref.read(supabaseClientProvider));
  return AuthController(ref, authRepo, profilesRepo);
});

class AuthController extends StateNotifier<String?> {
  final Ref _ref;
  final AuthRepository _authRepo;
  final ProfilesRepository _profilesRepo;

  AuthController(this._ref, this._authRepo, this._profilesRepo)
      : super(_authRepo.userId) {
    // Restored session: the fresh-login path (loginWithUsername ->
    // registerToken) never runs here, so without this the server-side device
    // token keeps whatever value — and APNs environment mapping — it had when
    // the session was first created. Re-register on every start; this also
    // wires the notification-tap deep link and the onTokenRefresh listener.
    if (state != null) {
      // Defer to a microtask, NOT `unawaited(...)`: an async function runs
      // synchronously up to its first `await`, so calling it directly here would
      // `ref.read(pushNotificationsManagerProvider)` — and, via registerToken,
      // eventBus/chats/notification providers — WHILE this very provider is still
      // being created. Those providers watch authControllerProvider → a reentrant
      // read → Riverpod drops authControllerProvider into an error state →
      // AuthStateHandler.build rethrows → a blank ErrorWidget (grey screen). Only
      // bit on a notification cold start, where the init order closes the cycle.
      // A microtask runs after this create() returns, so the reads are safe.
      unawaited(Future.microtask(_syncPushTokenForRestoredSession));
    }
  }

  Future<void> _syncPushTokenForRestoredSession() async {
    try {
      await _ref.read(pushNotificationsManagerProvider).registerToken();
      logger.info('FCM token re-registered for restored session');
    } catch (e) {
      logger.error('Failed to re-register FCM token on restore', error: e);
    }
  }

  /// Login anonymously and create profile with username
  Future<void> loginWithUsername(String username) async {
    // 1. Anonymous Auth
    await _authRepo.signInAnonymously();
    final userId = _authRepo.userId;
    
    if (userId == null) {
      throw Exception('Login failed: No user ID received');
    }

    // 2. Create Profile with username
    await _profilesRepo.createProfile(
      userId: userId,
      username: username,
    );

    // 3. Register FCM token for push notifications
    try {
      final pushManager = _ref.read(pushNotificationsManagerProvider);
      await pushManager.registerToken();
      logger.info('FCM token registered after login');
    } catch (e) {
      logger.error('Failed to register FCM token', error: e);
      // Don't throw - push notifications are optional
    }

    // 4. Update state
    state = userId;
  }

  /// Recover an existing identity from a 24-word recovery phrase (fresh device,
  /// no session). Runs the challenge-response with the recover-identity edge
  /// function, which leaves the Supabase client authenticated as the ORIGINAL
  /// user, then republishes per-chat keys and completes login. Throws
  /// [RecoveryException] on an invalid/unenrolled phrase.
  Future<void> recoverWithPhrase(String mnemonic) async {
    final userId = await _ref.read(recoveryServiceProvider).recover(mnemonic);

    // Republish per-chat public keys (the old keypairs are gone with the old
    // device); best-effort so a partial failure still lets the user in.
    try {
      await _ref.read(recoveryKeyReconcilerProvider).reconcile(userId);
    } catch (e) {
      logger.error('Post-recovery key reconciliation failed', error: e);
    }

    try {
      await _ref.read(pushNotificationsManagerProvider).registerToken();
    } catch (e) {
      logger.error('Failed to register FCM token after recovery', error: e);
    }

    state = userId;
  }

  /// Legacy login method (deprecated, use loginWithUsername instead)
  @Deprecated('Use loginWithUsername instead')
  Future<void> login() async {
    await _authRepo.signInAnonymously();
    state = _authRepo.userId;
  }

  Future<void> logout() async {
    // Clear profile cache
    final profilesController = _ref.read(profilesControllerProvider.notifier);
    profilesController.clearCache();
    
    // Unregister FCM token
    try {
      final pushManager = _ref.read(pushNotificationsManagerProvider);
      await pushManager.unregisterToken();
      logger.info('FCM token unregistered on logout');
    } catch (e) {
      logger.error('Failed to unregister FCM token', error: e);
    }
    
    // Delete the account server-side while the JWT is still valid (anonymous
    // accounts: logout == deletion — profile, memberships, messages, auth
    // user). Offline/failed calls fall through to the local logout; the
    // server data has no session pointing at it anymore.
    try {
      await _authRepo.deleteAccount();
      logger.info('Server-side account deleted on logout');
    } catch (e) {
      logger.error(
        'Server-side account deletion failed (offline?) — continuing logout',
        error: e,
      );
    }

    // Clear local encrypted data
    await _clearLocalData();

    // signOut() is a network call — if it throws (offline / flaky PWA) we must
    // NOT abort logout, otherwise the user is left "logged in" with half-wiped
    // local data and no way out. Swallow and fall through; the local session is
    // dropped either way and the server data has no session pointing at it.
    try {
      await _authRepo.signOut();
    } catch (e) {
      logger.error('signOut failed — continuing local logout', error: e);
    }

    try {
      await AppInit.reinitialize();
    } catch (e) {
      logger.error('reinitialize failed during logout — continuing', error: e);
    }

    // Re-arm the biometric gate so the next session must authenticate again.
    ChatsController.resetBiometricGate();

    state = null;
  }

  /// Sign-out for an installation that a recovery elsewhere replaced
  /// (installation_status.dart). Unlike [logout] it must NOT delete the
  /// account, which now lives on the other device, and must not end that
  /// device's session either. Only this device's push token, local data and
  /// session go.
  Future<void> leaveSupersededInstallation() async {
    _ref.read(profilesControllerProvider.notifier).clearCache();
    try {
      await _ref.read(pushNotificationsManagerProvider).unregisterToken();
    } catch (e) {
      logger.error('Failed to unregister FCM token', error: e);
    }
    await _clearLocalData();
    try {
      await _authRepo.signOutLocally();
    } catch (e) {
      logger.error('Local signOut failed — continuing', error: e);
    }
    try {
      await AppInit.reinitialize();
    } catch (e) {
      logger.error('reinitialize failed — continuing', error: e);
    }
    ChatsController.resetBiometricGate();
    state = null;
  }

  /// Clear all local encrypted data
  Future<void> _clearLocalData() async {
    try {
      // Clear chats from local database
      final chatsLocalRepo = _ref.read(chatsLocalRepositoryProvider);
      await chatsLocalRepo.clearAll();

      // Clear messages from local database
      final messagesLocalRepo = _ref.read(messagesLocalRepositoryProvider);
      await messagesLocalRepo.clearAll();

      // Who is in which chat and what they are called (CHAT-62).
      await _ref.read(rosterStoreProvider).clearAll();
      _ref.read(chatMembersCacheProvider).clear();

      // Optionally: Delete encryption key
      // (uncomment if you want users to re-authenticate on next login)
      final keyManager = _ref.read(encryptionKeyManagerProvider);
      await keyManager.deleteKey();

      // Identity and chat keys live in keychain services of their own on iOS,
      // which the deleteAll() of the wipe never reaches (CHAT-37). Left
      // behind, a new account on this device would publish the SAME identity
      // key, linking the old account to the new one. deleteKeyPair also drops
      // the in-memory copy the manager keeps for the session.
      await _ref.read(identityKeyManagerProvider).deleteKeyPair();
      await _ref.read(chatKeyPairManagerProvider).deleteAllKeys();

      // Wipe any iOS Share-Suggestions donations for the logged-out account.
      await ShareSuggestionsChannel.deleteAll();
    } catch (e, stackTrace) {
      logger.error(
        'Failed to clear local data during logout',
        tag: 'AuthController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
