// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../features/auth/auth_controller.dart';
import '../../../features/identity/installation_status.dart';

/// "This account now lives on another device." Shown across the top of the
/// chat list on an installation that was replaced by a recovery elsewhere.
///
/// Such a device has stopped publishing keys (installation_status.dart), so
/// it has to say why messages no longer arrive here. Its sign-out is
/// [AuthController.leaveSupersededInstallation], never `logout()`: for an
/// anonymous account that deletes the account on the server, and that would be
/// the very account the other device now uses.
class SupersededInstallationBanner extends ConsumerWidget {
  const SupersededInstallationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(authControllerProvider);
    if (userId == null) return const SizedBox.shrink();
    final status = ref.watch(installationStatusProvider(userId)).asData?.value;
    if (status != InstallationStatus.superseded) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('superseded_installation_banner'),
      color: scheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.devices_other_outlined,
                  size: 20, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'installation.superseded_title'.tr(),
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'installation.superseded_body'.tr(),
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        key: const ValueKey('superseded_sign_out'),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onTertiaryContainer,
                        ),
                        onPressed: () => _confirmSignOut(context, ref),
                        child: Text('installation.sign_out'.tr()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('installation.sign_out_title'.tr()),
        content: Text('installation.sign_out_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('installation.sign_out'.tr()),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(authControllerProvider.notifier).leaveSupersededInstallation();
  }
}
