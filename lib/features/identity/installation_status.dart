// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../profiles/profiles_repository.dart';

/// Whether this installation is still the one the account lives on.
enum InstallationStatus {
  /// The server carries this device's identity key (or none yet).
  current,

  /// Another installation published a different identity key after this one
  /// had published its own: the account was recovered elsewhere. This device
  /// must stop writing keys, or the two installations overwrite each other on
  /// every start (peers see "… hat neue Schlüssel erzeugt" again and again).
  superseded,

  /// Cannot tell (no local key, no record of an own publish, network error).
  /// Callers keep the behaviour from before this check existed.
  unknown,
}

/// Pure decision, see [InstallationStatus].
///
/// [lastPublished] is the identity key THIS installation last put on the
/// server. Only when the server holds something else although we published
/// our current key is it certain that someone else replaced it. A missing
/// record proves nothing: installs from before 1.32.2 never wrote one, and a
/// wiped secure storage loses it together with the key itself. A record of an
/// OLDER key of ours means our own rotation has not reached the server yet.
InstallationStatus decideInstallationStatus({
  required String? local,
  required String? server,
  required String? lastPublished,
}) {
  if (local == null) return InstallationStatus.unknown;
  if (server == null || server == local) return InstallationStatus.current;
  if (lastPublished == local) return InstallationStatus.superseded;
  return InstallationStatus.unknown;
}

/// The status for [userId], computed once per app run (one profile fetch).
/// Invalidate after this device publishes a new identity key.
final installationStatusProvider =
    FutureProvider.family<InstallationStatus, String>((ref, userId) async {
  final identity = ref.read(identityKeyManagerProvider);
  try {
    final local = await identity.publicKeyBase64();
    final profile = await ProfilesRepository(ref.read(supabaseClientProvider))
        .fetchProfile(userId);
    final server = profile?.identityPublicKey;
    final status = decideInstallationStatus(
      local: local,
      server: server,
      lastPublished: await identity.lastPublishedPublicKey(),
    );
    // Installs from before the record existed adopt it the first time the
    // server shows their own key, so a later takeover is recognised.
    if (local != null && server == local) {
      await identity.markPublished(local);
    }
    if (status == InstallationStatus.superseded) {
      logger.warning(
        'Identity key on the server is not ours any more: the account is '
        'active on another installation. Not publishing keys from here.',
        tag: 'InstallationStatus',
      );
    }
    return status;
  } catch (e) {
    logger.warning('Installation status unknown: $e', tag: 'InstallationStatus');
    return InstallationStatus.unknown;
  }
});
