// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/media/media_cache.dart';
import '../../features/media/media_blob_store.dart';
import '../../features/push_notifications/fcm_service.dart';
import '../../features/push_notifications/push_render_cache.dart';
import '../../features/reactions/emoji_compatibility.dart';
import '../config/supabase_config.dart';
import '../database/database_service.dart';
import '../logging/logger_service.dart';
import 'account_gone_guard.dart';
import 'maintenance_flag.dart';
import '../security/biometric_auth_service.dart';
import '../security/encryption_key_manager.dart';
import '../security/chat_key_pair_manager.dart';
import '../security/identity_key_manager.dart';
import '../security/key_locked_exception.dart';

/// App Initialization
///
/// Initialises every service the app needs before start:
/// - Environment variables (.env)
/// - Local database
/// - Encryption services
/// - Biometric authentication
/// - Supabase Client
class AppInit {
  static late DatabaseService dbService;

  static late FlutterSecureStorage storage;

  static late EncryptionKeyManager encryptionKeyManager;

  static late BiometricAuthService biometricAuth;

  static late Supabase supabase;

  static late FCMService? fcmService;

  static bool encryptionKeyAlreadyExists = false;

  /// Whether app lock is engaged at cold start, read BEFORE `runApp` so the
  /// lock gate can render its very first frame already locked (audit M6/M7). If
  /// the [AppLockController] instead started `locked:false` and flipped to true
  /// only after an async keychain read, the chat list (names/avatars/previews)
  /// would flash unlocked for a few frames — a privacy leak, and the wrong
  /// fail direction for a privacy gate. Derived from BOTH the enabled flag and a
  /// gated key (a gated key implies app-lock-on; see AppLockController._init).
  static bool appLockEngagedAtStartup = false;

  /// Storage key mirrored from AppLockController._enabledKey.
  static const String _appLockEnabledKey = 'app_lock_enabled_v1';

  static bool _isReinitializing = false;

  static bool _supabaseInitialized = false;

  static Future<void> initialize() async {
    // Flutter Bindings sicherstellen
    WidgetsFlutterBinding.ensureInitialized();

    // .env Datei laden
    await dotenv.load(fileName: '.env');

    // Measure once which of the youngest emoji this device can draw, so the
    // picker does not offer empty boxes. Deliberately NOT awaited: it lays out
    // 45 short strings and has no bearing on startup — nobody can open the
    // picker before an account exists.
    unawaited(EmojiCompatibility.warmUp());

    // Database initialisieren
    if (kIsWeb) {
      // Initialize sqflite for web
      databaseFactory = databaseFactoryFfiWeb;
    } else {
      // Initialize sqflite for desktop platforms
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
    }
    dbService = await _initializeDatabase();

    // Secure storage initialisieren
    storage = await _initializeSecureStorage();

    // Biometric auth checken
    biometricAuth = await _checkBiometrics();

    // Encryption initialisieren
    final (ekm, ekAlreadyExists) = await _initializeEncryption();
    encryptionKeyManager = ekm;
    encryptionKeyAlreadyExists = ekAlreadyExists;

    // Resolve the app-lock startup state now (before runApp) so the lock gate's
    // first frame is already correct — no unlocked flash of the chat list.
    final enabledFlag =
        (await storage.read(key: _appLockEnabledKey)) == 'true';
    appLockEngagedAtStartup =
        enabledFlag || await encryptionKeyManager.isKeyGated();

    // Supabase initialisieren
    supabase = await _initializeSupabase();

    // Initialize FCM (Firebase Cloud Messaging)
    fcmService = await initializeFcm();

    // Purge any decrypted-media temp files left over from a previous run that
    // was killed before the players could clean up (audit M8).
    await purgeMediaCache();

    // Check auth state
    final shouldReinit = await _checkAuthState();
    if (shouldReinit) {
      await reinitialize();
    }
  }

  static Future<DatabaseService> _initializeDatabase() async {
    // Initialize database service
    final ds = DatabaseService.instance;
    await ds.database; // Trigger database creation
    return ds;
  }

  static Future<FlutterSecureStorage> _initializeSecureStorage() async {
    // resetOnError:false by default — this pre-ProviderScope instance backs the
    // cold-start `app_lock_enabled_v1` read (line ~96). With the plugin default
    // `true`, a keystore-not-ready hiccup on that read would `deleteAll()` the
    // whole secure-storage namespace (the Galaxy KEM-wipe → false `keys_rotated`
    // class, audit #149 follow-up). Mirrors secureStorageProvider.
    final storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    );
    return storage;
  }

  static Future<BiometricAuthService> _checkBiometrics() async {
    // Check biometric availability
    final biometricAuth = BiometricAuthService();
    final isAvailable = await biometricAuth.isAvailable();

    if (isAvailable) {
      final types = await biometricAuth.getSupportedTypes();
      logger.debug('Biometric authentication available: $types');
    } else {
      logger.debug(
        'Warning: Biometric authentication not available on this device',
      );
    }

    return biometricAuth;
  }

  static Future<(EncryptionKeyManager, bool)> _initializeEncryption() async {
    // Initialize encryption key if it doesn't exist
    final keyManager = EncryptionKeyManager(storage, biometricAuth);

    final bool hasKey;
    try {
      hasKey = await keyManager.hasKey();
    } on PlatformException catch (e) {
      // resetOnError:false (#149 holistic anti-wipe): a corrupt / unreadable
      // Android keystore now THROWS here instead of silently wiping the
      // namespace and re-keying. Surface it typed so the bootstrap shows a
      // recovery screen (restore via recovery phrase) rather than a blank retry
      // — the keys are NOT destroyed, so this must never fall through to a wipe.
      throw SecureStorageUnreadableException(e);
    }
    if (!hasKey) {
      // Generate new encryption key on first launch
      await keyManager.generateKey();
      if (kDebugMode) {
        print('Generated new encryption key');
      }
    }

    return (keyManager, hasKey);
  }

  static Future<Supabase> _initializeSupabase() async {
    // Supabase is a process-wide singleton and calling Supabase.initialize a
    // second time throws. reinitialize() (logout) re-runs initialize(), so on
    // any subsequent pass reuse the existing instance instead of re-init.
    if (_supabaseInitialized) {
      logger.debug('Supabase already initialized — reusing existing instance');
      return Supabase.instance;
    }
    final useAndroid =
        !kIsWeb &&
        Platform.isAndroid &&
        SupabaseConfig.supabaseAndroidUrl.isNotEmpty;
    final supabase =
        await Supabase.initialize(
          url: useAndroid
              ? SupabaseConfig.supabaseAndroidUrl
              : SupabaseConfig.supabaseUrl,
          // Self-hosted Supabase still issues legacy anon keys; publishableKey
          // is only for the new sb_publishable_* keys.
          // ignore: deprecated_member_use
          anonKey: SupabaseConfig.supabaseAnonKey,
          // Default is retryAttempts: 0, so a single transient failure (iOS
          // Safari's "ClientException: Load failed" on large media uploads)
          // was final. The storage client's retryIf already matches
          // ClientException/TimeoutException — give it actual attempts.
          storageOptions: const StorageClientOptions(retryAttempts: 3),
          debug: kDebugMode, // Nur für Development
        ).onError((error, stackTrace) {
          error ??= Exception('Error initializing Supabase');
          logger.error(
            'Error initializing Supabase',
            error: error,
            stackTrace: stackTrace,
          );
          throw error;
        });
    _supabaseInitialized = true;
    logger.info('Supabase initialized: $supabase');
    return supabase;
  }

  /// Deadline for the push registration at startup.
  ///
  /// Not a gut feeling but the consequence of a fault: on **web**,
  /// `FCMService.initialize()` asks for the notification permission, and
  /// `Notification.requestPermission()` **does not resolve its promise while
  /// the browser dialog is unanswered** — measured on 2026-08-25: six seconds,
  /// no answer, and arbitrarily longer after that. Since startup awaited this
  /// result, `initialize()` never returned, `runApp` never ran, and the page
  /// stayed in the loading screen forever.
  ///
  /// Anyone who had answered the dialog once noticed nothing of it — which is
  /// why this long counted as a quirk of staging. But it hit every origin for
  /// which no answer had been stored yet, production included; it just went
  /// unseen there because our own browsers had long since answered.
  static const Duration fcmInitDeadline = Duration(seconds: 8);

  /// Seam for the test: replaces the actual startup with something that never
  /// answers — exactly the case that held the page in the loading screen.
  @visibleForTesting
  static Future<void> Function()? fcmStarterForTest;

  @visibleForTesting
  static Future<FCMService?> initializeFcm() async {
    final fcm = FCMService();
    final starte = fcmStarterForTest ?? fcm.initialize;
    try {
      await starte().timeout(fcmInitDeadline);
      logger.info('FCM initialized successfully');
      return fcm;
    } on TimeoutException {
      // Deliberately NOT cancelled: a timeout in Dart does not abort the work
      // that is running. If the user answers the dialog later, `initialize()`
      // runs to the end and sets `isInitialized` on the singleton — and the
      // path taken at sign-in (`refreshToken()`) fetches the token afterwards.
      // Until then the app simply starts without push, which it has to be able
      // to do anyway (on Linux there is no Firebase at all).
      logger.warning(
        'FCM meldete sich nicht innerhalb von ${fcmInitDeadline.inSeconds}s — '
        'der Start geht ohne Push weiter (auf Web hängt das an einem '
        'unbeantworteten Berechtigungsdialog).',
      );
      return null;
    } catch (e, stackTrace) {
      logger.error('Failed to initialize FCM', error: e, stackTrace: stackTrace);
      // Don't throw - FCM is optional, app should work without it
      return null;
    }
  }

  /// How long the start waits for the session check. gotrue retries a failed
  /// refresh for about 12.5 s before it gives up (measured 2026-10-29, both
  /// with a refused connection and an unknown host); the splash screen stood
  /// that long on every start without network (CHAT-63). Online the answer
  /// comes within a second.
  static const Duration authCheckDeadline = Duration(seconds: 4);

  /// [refresh] with [authCheckDeadline]; null when it did not answer in time.
  /// Errors pass through: an explicit "user not found" must still reach the
  /// grace logic.
  @visibleForTesting
  static Future<AuthResponse?> refreshWithDeadline(
    Future<AuthResponse> Function() refresh, {
    Duration deadline = authCheckDeadline,
  }) async {
    try {
      return await refresh().timeout(deadline);
    } on TimeoutException {
      return null;
    }
  }

  /// Decides whether local data must be wiped at startup.
  ///
  /// Wiping is **destructive and irreversible**: it deletes the encryption key,
  /// the local SQLite DB and every private chat key. Because the server clears
  /// a message's ciphertext the moment it's read, the local DB is the *only*
  /// readable copy of already-read messages — so a false-positive wipe
  /// permanently loses chat history. We therefore auto-wipe in exactly one
  /// case: the server **explicitly rejected** a present session token. A merely
  /// absent session, an offline/transient failure, or a startup restoration
  /// race never triggers a wipe (an explicit logout wipes via its own path).
  static Future<bool> _checkAuthState() async {
    final session = supabase.client.auth.currentSession;

    if (session == null) {
      // Ambiguous — almost always a session-restoration race (supabase_flutter
      // hasn't reloaded the persisted session yet), an offline launch, or the
      // app having been killed; only rarely a real logout (which already wiped
      // on its own). Never auto-wipe here. Keep local data; the app routes to
      // the login screen if there is genuinely no session.
      logger.debug(
        encryptionKeyAlreadyExists
            ? 'No active session at startup — keeping local data (no auto-wipe)'
            : 'First launch / no prior session',
      );
      return false;
    }

    logger.debug('Session found');
    try {
      final response = await refreshWithDeadline(
        () => supabase.client.auth.refreshSession(session.refreshToken),
      );
      if (response == null) {
        // No answer in time: offline or a dead link, both ambiguous. The
        // refresh keeps running in the background and the client keeps using
        // the session; nothing is decided, nothing is wiped.
        logger.info('Session check took too long — starting with local data');
        return false;
      }
      if (response.user != null) {
        logger.debug('User found: ${response.user!.id}');
        // The server knows us again — any "account gone" mark was a blip. It
        // MUST go here, otherwise the counter would stay put and a second blip
        // weeks later would tear through the threshold.
        await clearAccountGone(storage);
      } else {
        // Refreshed but no user is an odd state; stay conservative and keep
        // data rather than destroying it — the app can re-authenticate.
        logger.warning('Session refreshed but no user returned — keeping data');
      }
      return false; // Valid (or ambiguous-but-safe) session — never wipe.
    } catch (e) {
      if (!isAccountGoneVerdict(e, keyExists: encryptionKeyAlreadyExists)) {
        return false;
      }
      return _accountGoneShouldWipe();
    }
  }

  /// The server says "this user does not exist" — now what?
  ///
  /// Two brakes covering different cases (Gerry, 2026-08-31):
  ///
  /// * The **maintenance switch** is the deliberate override for the planned
  ///   case — before a server deploy, or in the middle of an incident.
  /// * The **grace period** is the automatic floor for the unexpected. It works
  ///   without a network and without anyone thinking of it in time.
  ///
  /// During maintenance the launch is **not counted**. Otherwise a long
  /// maintenance window would quietly pile up launches, and the second the flag
  /// falls the threshold would be torn through — the switch would then not have
  /// prevented the deletion but merely dammed it up.
  static Future<bool> _accountGoneShouldWipe() async {
    if (await MaintenanceFlag.isActive()) {
      logger.warning(
        'Wartungsmodus aktiv — der Server kennt das Konto nicht, es wird '
        'trotzdem NICHTS geloescht und der Start nicht gezaehlt.',
        tag: 'AccountGone',
      );
      return false;
    }
    final now = DateTime.now().toUtc();
    final stand = await recordAccountGone(storage, now);
    if (!accountGoneIsFinal(stand, now)) return false;
    logger.warning(
      'Konto seit ${stand.firstSeen.toIso8601String()} und ueber '
      '${stand.launches} Starts hinweg nicht existent — die Karenz ist '
      'abgelaufen, die lokalen Daten werden jetzt geloescht.',
      tag: 'AccountGone',
    );
    return true;
  }

  /// Has the server EXPLICITLY declared the account non-existent?
  ///
  /// Only an EXPLICIT server rejection of the token counts. gotrue throws
  /// [AuthRetryableFetchException] for offline/timeout/unreachable failures,
  /// and it *extends* [AuthException] — so it must be excluded first, or a
  /// single offline launch would destroy the key, DB and all chat keys.
  ///
  /// Was called `shouldWipeForRefreshError` until 2026-08-31 and was thereby
  /// the decision as well. It is not any more: a "yes" here only means the
  /// server has passed that judgement — whether anything is deleted because of
  /// it is decided by the maintenance switch and the grace period in
  /// [_accountGoneShouldWipe]. After the change the old name would have claimed
  /// the wrong thing.
  @visibleForTesting
  static bool isAccountGoneVerdict(Object e, {required bool keyExists}) {
    if (e is AuthRetryableFetchException) {
      logger.warning(
        'Session refresh failed (network, retryable) — keeping local session',
        error: e,
      );
      return false;
    }
    if (e is AuthException) {
      // A token/session problem — an expired or reused refresh token (the
      // multi-client race when an installed PWA and the still-open browser tab
      // share one persisted session and both rotate it), a bad JWT, a missing
      // session — is NOT proof the account is gone; the user can simply
      // re-authenticate. Wiping on it destroyed the only local copy of
      // already-read messages. Only an explicit "user no longer exists" verdict
      // (`user_not_found`) justifies purging local data at startup.
      final code = e.code?.toLowerCase();
      logger.warning(
        'Session refresh rejected by server: ${e.message} (code=$code)',
      );
      if (code == 'user_not_found' && keyExists) {
        logger.debug('Account no longer exists server-side and a prior key '
            'exists; wiping');
        return true;
      }
      return false;
    }
    // Anything else is transient/unknown — never wipe on uncertainty.
    logger.warning(
      'Session refresh failed (transient) — keeping local session',
      error: e,
    );
    return false;
  }

  static Future<void> _deleteData() async {
    try {
      await encryptionKeyManager.deleteKey();
      logger.debug('Encryption key deleted');
    } catch (e) {
      logger.error('Error deleting encryption key', error: e);
    }

    try {
      await dbService.deleteDatabase();
      logger.debug('Database deleted');
    } catch (e) {
      logger.error('Error deleting database', error: e);
    }

    try {
      // Before deleteAll(): on iOS identity and chat keys sit in keychain
      // services of their own that deleteAll() does not reach (CHAT-37), and
      // the chat keys are found by reading them, which needs them still there.
      await IdentityKeyManager(storage).deleteKeyPair();
      await ChatKeyPairManager(storage).deleteAllKeys();
      logger.debug('Identity and chat keys deleted');
    } catch (e) {
      logger.error('Error deleting identity/chat keys', error: e);
    }

    try {
      await storage.deleteAll();
      logger.debug('Secure storage deleted');
    } catch (e) {
      logger.error('Error deleting secure storage', error: e);
    }

    try {
      // The push name table is a plaintext list of who you talk to; it must
      // not outlive the account on this device (CHAT-38).
      await PushRenderCache.clear();
      logger.debug('Push name cache cleared');
    } catch (e) {
      logger.error('Error clearing push name cache', error: e);
    }

    try {
      await supabase.client.auth.signOut();
      logger.debug('User signed out');
    } catch (e) {
      logger.error('Error signing out user', error: e);
    }

    try {
      // Drop decrypted media the players wrote to disk (audit M8) — otherwise
      // plaintext photos/videos would survive a logout / account switch.
      await purgeMediaCache();
      // The kept encrypted copies too: they belong to the account that left.
      await platformMediaBlobStore().clear();
      logger.debug('Media cache purged');
    } catch (e) {
      logger.error('Error purging media cache', error: e);
    }
  }

  static Future<void> reinitialize() async {
    if (_isReinitializing) {
      logger.warning('Reinitialization already in progress');
      return;
    }
    _isReinitializing = true;
    logger.info('Reinitializing app...');

    try {
      logger.debug('Deleting data...');
      await _deleteData();
      logger.debug('Data deleted');
      await initialize();
    } catch (e) {
      logger.error('Error during reinitialization', error: e);
    } finally {
      _isReinitializing = false;
    }
  }
}
