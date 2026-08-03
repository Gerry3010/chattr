// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import '../../core/security/key_locked_exception.dart';
import '../../core/security/security_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/theme_controller.dart';
import '../../features/app_lock/app_lock_controller.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/read_receipts/read_receipts_controller.dart';
import '../../features/share_suggestions/share_suggestions_controller.dart';
import '../../features/screen_security/screen_security_controller.dart';
import '../../features/profiles/avatar_actions.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/profiles_controller.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import '../../core/notifications/notification_sound_controller.dart';
import '../../core/notifications/notification_sounds.dart';
import '../qr/qr_display_screen.dart';
import 'backup_settings_screen.dart';
import 'dev_log_screen.dart';
import 'recovery_settings_screen.dart';
import 'blocked_users_screen.dart';
import 'mcp_settings_screen.dart';
import 'notification_sound_screen.dart';
import 'theme_settings_screen.dart';

/// Consolidated app settings: profile (name/avatar/QR), theme selection, and
/// account actions (logout/wipe).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(authControllerProvider);
    final profile = userId == null ? null : ref.watch(profileProvider(userId));
    final selectedTheme = ref.watch(themeControllerProvider);
    final selectedSoundId = ref.watch(notificationSoundControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text('settings.title'.tr())),
      body: ListView(
        children: [
          // ── Profile ──────────────────────────────────────────────
          if (userId != null)
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Stack(
                children: [
                  UserAvatar(userId: userId, radius: 26),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Icon(Icons.edit,
                          size: 11,
                          color: Theme.of(context).colorScheme.onPrimary),
                    ),
                  ),
                ],
              ),
              title: Text(
                profile?.username ?? 'chat_detail.unknown_user'.tr(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text('settings.tap_avatar'.tr()),
              trailing: IconButton(
                key: const ValueKey('settings_edit_username'),
                icon: const Icon(Icons.drive_file_rename_outline),
                tooltip: 'settings.edit_username'.tr(),
                onPressed: () =>
                    _editUsername(context, ref, userId, profile?.username),
              ),
              onTap: () => pickAndUploadAvatar(context, ref, userId),
            ),
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: Text('settings.my_qr'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const QrDisplayScreen()),
            ),
          ),
          const Divider(),

          // ── Appearance (theme submenu) ───────────────────────────
          ListTile(
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: selectedTheme.swatch,
              child: Icon(selectedTheme.icon, size: 16, color: Colors.white),
            ),
            title: Text('settings.appearance'.tr()),
            subtitle: Text(selectedTheme.label.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const ThemeSettingsScreen(),
              ),
            ),
          ),
          const Divider(),

          // ── Notifications (sound picker) ─────────────────────────
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text('settings.notification_sound'.tr()),
            subtitle:
                Text(notificationSoundById(selectedSoundId).labelKey.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const NotificationSoundScreen(),
              ),
            ),
          ),
          const Divider(),

          // ── Privacy (read receipts) ──────────────────────────────
          _SectionHeader('settings.privacy'.tr()),
          _ReadReceiptsTile(),
          _ShareSuggestionsTile(),
          const Divider(),

          // ── Security (app lock) ──────────────────────────────────
          _SectionHeader('settings.security'.tr()),
          _AppLockSection(),
          _ScreenSecurityTile(),
          const Divider(),

          // ── Account ──────────────────────────────────────────────
          _SectionHeader('settings.account'.tr()),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text('settings.blocked_users'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const BlockedUsersScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text('settings.mcp.title'.tr()),
            subtitle: Text('settings.mcp.subtitle'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const McpSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text('settings.backup.title'.tr()),
            subtitle: Text('settings.backup.subtitle'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const BackupSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: Text('settings.recovery.title'.tr()),
            subtitle: Text('settings.recovery.subtitle'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const RecoverySettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text('settings.logout'.tr(),
                style: const TextStyle(color: Colors.red)),
            subtitle: Text('settings.logout_hint'.tr()),
            onTap: () => _confirmLogout(context, ref),
          ),
          const SizedBox(height: 16),
          const _VersionFooter(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.logout'.tr()),
        content: Text('settings.logout_confirm'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('settings.logout'.tr()),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }

  Future<void> _editUsername(
    BuildContext context,
    WidgetRef ref,
    String userId,
    String? currentName,
  ) async {
    final controller = TextEditingController(text: currentName ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.edit_username'.tr()),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'login.username_label'.tr(),
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: Text('common.ok'.tr()),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(profilesControllerProvider.notifier)
          .updateUsername(userId: userId, username: newName);
      messenger.showSnackBar(
        SnackBar(content: Text('settings.username_updated'.tr())),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }
}

/// App version + build number, centered below the settings list. Tapping it
/// seven times opens the hidden [DevLogScreen] (Sleep-App-style) so a tester
/// can grab a copyable log without a wired-up debug device.
class _VersionFooter extends ConsumerStatefulWidget {
  const _VersionFooter();

  @override
  ConsumerState<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends ConsumerState<_VersionFooter> {
  static const int _tapsToReveal = 7;
  int _taps = 0;

  Future<void> _onTap() async {
    _taps++;
    if (_taps >= _tapsToReveal) {
      _taps = 0;
      // The dev log contains diagnostic metadata (peer user_ids, chat_ids,
      // storage paths, stack traces) — a real privacy leak on an unlocked
      // device. Gate it behind a FRESH biometric/passcode re-auth (audit L5),
      // bypassing the session cache so a prior chat-open unlock doesn't waive it.
      final ok = await ref.read(biometricAuthServiceProvider).authenticate(
            localizedReason: 'Authenticate to open the developer log',
            forcePrompt: true,
          );
      if (!ok || !mounted) return;
      Navigator.push(
        context,
        appPageRoute<void>(builder: (_) => const DevLogScreen()),
      );
    } else if (_taps >= _tapsToReveal - 3) {
      // Gentle hint on the last few taps (Sleep-App feel).
      final left = _tapsToReveal - _taps;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 600),
            content: Text('Dev-Log in $left …'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
              child: Text(
                'settings.version'.tr(
                  namedArgs: {
                    'version': info.version,
                    'build': info.buildNumber,
                  },
                ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Screenshot / screen-recording protection toggle (Android FLAG_SECURE).
class _ScreenSecurityTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(screenSecurityProvider);
    return SwitchListTile(
      key: const ValueKey('screen_security_toggle'),
      secondary: const Icon(Icons.screenshot_monitor_outlined),
      title: Text('screen_security.enable'.tr()),
      subtitle: Text('screen_security.enable_hint'.tr()),
      value: enabled,
      onChanged: (v) =>
          ref.read(screenSecurityProvider.notifier).setEnabled(v),
    );
  }
}

/// Reciprocal read-receipt privacy toggle. Off ⇒ we never tell senders we read
/// their message (their tick caps at "delivered") and we stop seeing others'
/// read receipts. "Delivered" always works. See [sendReadReceiptsProvider].
class _ReadReceiptsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(sendReadReceiptsProvider);
    return SwitchListTile(
      key: const ValueKey('read_receipts_toggle'),
      secondary: const Icon(Icons.done_all),
      title: Text('read_receipts.enable'.tr()),
      subtitle: Text('read_receipts.enable_hint'.tr()),
      value: enabled,
      onChanged: (v) =>
          ref.read(sendReadReceiptsProvider.notifier).setEnabled(v),
    );
  }
}

/// iOS Share-Suggestions toggle (default ON). When on, sending donates the
/// conversation (recipient names + ids, never content) to iOS' on-device
/// share-sheet suggestion store. iOS-only — hidden elsewhere (the channel no-ops
/// there anyway). See [shareSuggestionsEnabledProvider].
class _ShareSuggestionsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(shareSuggestionsEnabledProvider);
    return SwitchListTile(
      key: const ValueKey('share_suggestions_toggle'),
      secondary: const Icon(Icons.ios_share),
      title: Text('share_suggestions.enable'.tr()),
      subtitle: Text('share_suggestions.enable_hint'.tr()),
      value: enabled,
      onChanged: (v) =>
          ref.read(shareSuggestionsEnabledProvider.notifier).setEnabled(v),
    );
  }
}

/// App-lock settings: enable/disable, set/change/remove the passcode.
/// Enabling on a biometrics-less device forces setting a passcode first.
class _AppLockSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lockState = ref.watch(appLockControllerProvider);
    final controller = ref.read(appLockControllerProvider.notifier);

    return Column(
      children: [
        SwitchListTile(
          key: const ValueKey('app_lock_toggle'),
          secondary: const Icon(Icons.lock_outline),
          title: Text('app_lock.enable'.tr()),
          subtitle: Text('app_lock.enable_hint'.tr()),
          value: lockState.enabled,
          onChanged: (enabled) async {
            if (enabled &&
                !lockState.hasPasscode &&
                !await controller.biometricsAvailable()) {
              // No biometrics on this device — a passcode is mandatory.
              if (!context.mounted) return;
              final set = await _showPasscodeDialog(context, controller);
              if (!set) return;
            }
            try {
              await controller.setEnabled(
                enabled,
                unlockReason: 'app_lock.unlock_reason'.tr(),
              );
            } on KeyGatingUnavailableException {
              // The at-rest key binding could not be established/verified on
              // this device (no device auth, or the unlock round-trip failed /
              // was cancelled). App lock stays OFF — never claim protection we
              // cannot deliver.
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('app_lock.at_rest_unavailable'.tr()),
                  ),
                );
              }
            }
          },
        ),
        ListTile(
          key: const ValueKey('app_lock_passcode_tile'),
          leading: const Icon(Icons.pin_outlined),
          title: Text(
            (lockState.hasPasscode
                    ? 'app_lock.change_passcode'
                    : 'app_lock.set_passcode')
                .tr(),
          ),
          onTap: () => _showPasscodeDialog(context, controller),
        ),
        if (lockState.hasPasscode)
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: Text('app_lock.remove_passcode'.tr()),
            subtitle: Text('app_lock.remove_passcode_hint'.tr()),
            onTap: () => controller.removePasscode(),
          ),
      ],
    );
  }

  /// Returns true when a passcode was set.
  Future<bool> _showPasscodeDialog(
    BuildContext context,
    AppLockController controller,
  ) async {
    final first = TextEditingController();
    final second = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('app_lock.set_passcode'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('app_lock_passcode_input_1'),
              controller: first,
              obscureText: true,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'app_lock.passcode_hint'.tr(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('app_lock_passcode_input_2'),
              controller: second,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'app_lock.passcode_repeat'.tr(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            key: const ValueKey('app_lock_passcode_save'),
            onPressed: () {
              // Min length 4, both entries equal — otherwise stay open.
              if (first.text.length >= 4 && first.text == second.text) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: Text('chat_detail.save_changes'.tr()),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.setPasscode(first.text);
      return true;
    }
    return false;
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
