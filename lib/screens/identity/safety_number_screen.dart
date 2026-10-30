// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/identity/identity_verification_controller.dart';
import '../../features/identity/identity_verification_repository.dart';
import '../../features/profiles/profiles_controller.dart';
import '../../core/network/load_error_view.dart';

/// Signal-style verification screen for one peer (audit C1): shows the shared
/// 60-digit safety number, the current trust state, and lets the user mark the
/// peer verified after an out-of-band comparison — or accept a changed key
/// after a reinstall/recovery. Warn-only: nothing here ever blocks sending.
class SafetyNumberScreen extends ConsumerWidget {
  final String userId;
  final String username;

  const SafetyNumberScreen({
    super.key,
    required this.userId,
    required this.username,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Best-effort self-heal: (re)publish our identity key — a device whose
    // startup publish failed silently would otherwise show "no key" to every
    // peer forever. Idempotent; result only logged.
    ref.watch(identityPublishRetryProvider);
    final stateAsync = ref.watch(peerVerificationProvider(userId));
    final numberAsync = ref.watch(safetyNumberProvider(userId));
    final state =
        stateAsync.asData?.value ?? IdentityVerificationState.unknown;

    return Scaffold(
      appBar: AppBar(title: Text('identity.title'.tr())),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    username,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                _stateChip(context, state),
              ],
            ),
            const SizedBox(height: 24),
            if (state == IdentityVerificationState.changed) ...[
              _changedWarning(context, ref),
              const SizedBox(height: 24),
            ],
            numberAsync.when(
              data: (shown) => shown == null
                  ? _unknownInfo(context, ref)
                  : _numberCard(context, shown.number),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => LoadErrorView(
                error: e,
                compact: true,
                onRetry: () => ref.invalidate(safetyNumberProvider(userId)),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'identity.explain'.tr(args: [username]),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'identity.scan_hint'.tr(args: [username]),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            if (state == IdentityVerificationState.unverified)
              FilledButton.icon(
                icon: const Icon(Icons.verified_user),
                label: Text('identity.mark_verified'.tr()),
                onPressed: () => _pinCurrentKey(
                  context,
                  ref,
                  verified: true,
                  snack: 'identity.verified_snack'.tr(args: [username]),
                  comparedKey: numberAsync.value?.peerKey,
                ),
              ),
            if (state == IdentityVerificationState.verified)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.verified_user, color: Colors.green),
                  const SizedBox(width: 8),
                  Text(
                    'identity.state_verified'.tr(),
                    style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _numberCard(BuildContext context, String formatted) {
    final groups = formatted.split(' ');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'identity.safety_number'.tr(),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final g in groups)
                Text(
                  g,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    letterSpacing: 2,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unknownInfo(BuildContext context, WidgetRef ref) {
    // Which side is actually missing? MY key missing/locked → offer an
    // explicit publish button; peer key missing → explain (with a dedicated
    // hint when the peer's profile isn't even readable yet — pending 1:1).
    final myKeyAsync = ref.watch(myIdentityPublicKeyProvider);
    final myKeyMissing = myKeyAsync.hasError;
    // LOST is not the same as "not published yet" — see [identityRemedyFor].
    final remedy = identityRemedyFor(myKeyAsync.error);
    final myKeyLost = remedy == IdentityRemedy.regenerate;
    final peerProfile = ref
        .read(profilesControllerProvider.notifier)
        .getCachedProfile(userId, returnNonExistent: true);
    final peerUnreadable = !(peerProfile?.exists ?? true);

    final String text = myKeyLost
        ? 'identity.my_key_lost'.tr()
        : myKeyMissing
            ? 'identity.my_key_missing'.tr()
            : peerUnreadable
                ? 'identity.pending_peer_info'.tr(args: [username])
                : 'identity.unknown_explain'.tr(args: [username]);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
            ],
          ),
          if (myKeyMissing) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: myKeyLost
                  ? FilledButton.icon(
                      icon: const Icon(Icons.key),
                      label: Text('identity.regenerate_key'.tr()),
                      onPressed: () => _regenerateKey(context, ref),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.publish),
                      label: Text('identity.publish_now'.tr()),
                      onPressed: () => _publishNow(context, ref),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  /// Explicit retry for the silent self-heal: mint (if possible) + publish our
  /// identity key, then re-resolve every identity provider on this screen.
  Future<void> _publishNow(BuildContext context, WidgetRef ref) async {
    final ok = await ref.refresh(identityPublishRetryProvider.future);
    ref.invalidate(myIdentityPublicKeyProvider);
    ref.invalidate(safetyNumberProvider(userId));
    ref.invalidate(peerVerificationProvider(userId));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'identity.publish_done'.tr() : 'identity.publish_failed'.tr(),
        ),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  /// Explicit, confirmed re-mint for a device whose identity seed is gone.
  /// The confirmation is not ceremony: a new key flips every peer's safety
  /// number, so the user has to have been told that before it happens.
  Future<void> _regenerateKey(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('identity.regenerate_confirm_title'.tr()),
        content: Text('identity.regenerate_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('identity.regenerate_confirm_cta'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await ref.read(identityRecoveryProvider).regenerateAndPublish();
    ref.invalidate(myIdentityPublicKeyProvider);
    ref.invalidate(safetyNumberProvider(userId));
    ref.invalidate(peerVerificationProvider(userId));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'identity.regenerate_done'.tr()
              : 'identity.regenerate_failed'.tr(),
        ),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  Widget _changedWarning(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[100],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_bad, color: Colors.red[900]),
              const SizedBox(width: 8),
              Text(
                'identity.changed_title'.tr(),
                style: TextStyle(
                  color: Colors.red[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'identity.changed_explain'.tr(args: [username]),
            style: TextStyle(color: Colors.red[900]),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _pinCurrentKey(
                context,
                ref,
                verified: false,
                snack: 'identity.accepted_snack'.tr(),
              ),
              child: Text(
                'identity.accept_new_key'.tr(),
                style: TextStyle(
                  color: Colors.red[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pin the peer's CURRENT published identity key (mark-verified after an
  /// out-of-band comparison, or accept-new-key after a change warning), then
  /// refresh every provider that renders trust state.
  Future<void> _pinCurrentKey(
    BuildContext context,
    WidgetRef ref, {
    required bool verified,
    required String snack,
    String? comparedKey,
  }) async {
    try {
      final profile = await ref
          .read(profilesControllerProvider.notifier)
          .getProfile(userId);
      final key = profile.identityPublicKey;
      if (key == null || key.isEmpty) return;
      // Verified means: the number the user compared. If the key changed
      // between showing the number and the tap, the comparison was about a
      // different key (CHAT-42). Show the new number instead of pinning.
      if (verified && (comparedKey == null || comparedKey != key)) {
        ref.invalidate(safetyNumberProvider(userId));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('identity.key_changed_compare_again'.tr())),
          );
        }
        return;
      }
      await ref
          .read(identityVerificationRepositoryProvider)
          .pin(userId, key, verified: verified);
      ref.invalidate(peerVerificationProvider(userId));
      ref.invalidate(chatVerificationProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(snack)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('common.error'.tr(args: ['$e'])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _stateChip(BuildContext context, IdentityVerificationState state) {
    final (color, icon, label) = switch (state) {
      IdentityVerificationState.verified => (
          Colors.green,
          Icons.verified_user,
          'identity.state_verified'.tr()
        ),
      IdentityVerificationState.changed => (
          Colors.red,
          Icons.gpp_bad,
          'identity.state_changed'.tr()
        ),
      IdentityVerificationState.unverified => (
          Colors.grey,
          Icons.shield_outlined,
          'identity.state_unverified'.tr()
        ),
      IdentityVerificationState.unknown => (
          Colors.grey,
          Icons.help_outline,
          'identity.state_unknown'.tr()
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
