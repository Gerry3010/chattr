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
import '../../features/profile/username_rules.dart';
import '../../features/read_receipts/read_receipts_controller.dart';
import '../../features/settings/media_quality_controller.dart';
import '../../features/share_suggestions/share_suggestions_channel.dart';
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
import 'about_section.dart';
import 'dev_log_screen.dart';
import 'recovery_settings_screen.dart';
import 'blocked_users_screen.dart';
import 'mcp_settings_screen.dart';
import 'notification_sound_screen.dart';
import 'theme_settings_screen.dart';
import '../../features/push_notifications/push_media_kind_setting.dart';
import '../../features/push_notifications/push_reaction_emoji_setting.dart';

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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Stack(
                children: [
                  UserAvatar(userId: userId, radius: 26),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Icon(
                        Icons.edit,
                        size: 11,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
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
              appPageRoute<void>(builder: (_) => const ThemeSettingsScreen()),
            ),
          ),
          const Divider(),

          // ── Notifications (sound picker) ─────────────────────────
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text('settings.notification_sound'.tr()),
            subtitle: Text(
              notificationSoundById(selectedSoundId).labelKey.tr(),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const NotificationSoundScreen(),
              ),
            ),
          ),
          const Divider(),

          // ── Medien ───────────────────────────────────────────────
          _SectionHeader('settings.media'.tr()),
          _MediaQualityTile(),
          const Divider(),

          // ── Privacy (read receipts) ──────────────────────────────
          _SectionHeader('settings.privacy'.tr()),
          _ReadReceiptsTile(),
          _PushMediaKindTile(),
          _PushReactionEmojiTile(),
          _ShareSuggestionsTile(),
          const Divider(),

          // ── Security (app lock) ──────────────────────────────────
          _SectionHeader('settings.security'.tr()),
          _AppLockSection(),
          // FLAG_SECURE is an Android API; on iOS, web and desktop the switch
          // did nothing but still sat there promising protection. Hide it
          // instead of shipping a control that lies (its hint used to carry an
          // "(Android only)" apology, which is not a fix).
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
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
              appPageRoute<void>(
                builder: (_) => const RecoverySettingsScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(
              'settings.logout'.tr(),
              style: const TextStyle(color: Colors.red),
            ),
            subtitle: Text('settings.logout_hint'.tr()),
            onTap: () => _confirmLogout(context, ref),
          ),
          const AboutSection(),
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
          maxLength: kMaxUsernameLength,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'login.username_label'.tr()),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
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
      final ok = await ref
          .read(biometricAuthServiceProvider)
          .authenticate(
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

/// A privacy switch whose explanation lives behind an ⓘ instead of under the
/// title.
///
/// The privacy section had grown into a wall of small print: four switches,
/// each with two or three lines of justification beneath it. The explanations
/// are worth having — they say what a setting actually costs — but printed all
/// at once they stop being read, and the section stops being scannable. Behind
/// the ⓘ they are one tap away for whoever wants them.
/// One row of the privacy section: icon, label, an ⓘ that explains the setting,
/// and the switch.
///
/// Public (rather than library-private) only so a widget test can pin the ⓘ
/// column down — that alignment is purely visual and nothing else would catch
/// it drifting.
@visibleForTesting
class PrivacySwitchTile extends StatelessWidget {
  const PrivacySwitchTile({
    super.key,
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.info,
    required this.value,
    required this.onChanged,
  });

  final String tileKey;
  final IconData icon;
  final String title;
  final String info;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: ValueKey(tileKey),
      secondary: Icon(icon),
      title: Row(
        children: [
          // Expanded, NOT Flexible: a short label would otherwise take only the
          // width it needs and drag the ⓘ along behind it, while a label that
          // wraps pushes its ⓘ out to the edge. The icons then sit at
          // different x-positions per row — visible the moment one entry fits
          // on a single line and its neighbours don't. Expanded gives every
          // label the full remaining width, so the ⓘ forms a column.
          Expanded(child: Text(title)),
          const SizedBox(width: 6),
          // Its own tap target, so hitting the ⓘ never toggles the switch by
          // accident — the two actions sit millimetres apart.
          InkWell(
            key: ValueKey('${tileKey}_info'),
            customBorder: const CircleBorder(),
            onTap: () => _showInfo(context),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.info_outline,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      value: value,
      onChanged: onChanged,
    );
  }

  void _showInfo(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text(info, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// Screenshot / screen-recording protection toggle (Android FLAG_SECURE).
class _ScreenSecurityTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(screenSecurityProvider);
    return PrivacySwitchTile(
      tileKey: 'screen_security_toggle',
      icon: Icons.screenshot_monitor_outlined,
      title: 'screen_security.enable'.tr(),
      info: 'screen_security.enable_hint'.tr(),
      value: enabled,
      onChanged: (v) => ref.read(screenSecurityProvider.notifier).setEnabled(v),
    );
  }
}

/// Whether photos and videos are sent downscaled. Default OFF — full quality is
/// the preset, see [mediaQualityProvider]. The switch stands on every platform:
/// images are downscaled everywhere, videos only on Android and iOS, and that
/// is exactly what the explanatory text says.
class _MediaQualityTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final smaller = ref.watch(mediaQualityProvider) == MediaQuality.smaller;
    return PrivacySwitchTile(
      tileKey: 'media_quality_toggle',
      icon: Icons.compress,
      title: 'media_quality.enable'.tr(),
      info: 'media_quality.enable_hint'.tr(),
      value: smaller,
      onChanged: (v) => ref.read(mediaQualityProvider.notifier).setSmaller(v),
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
    return PrivacySwitchTile(
      tileKey: 'read_receipts_toggle',
      icon: Icons.done_all,
      title: 'read_receipts.enable'.tr(),
      info: 'read_receipts.enable_hint'.tr(),
      value: enabled,
      onChanged: (v) =>
          ref.read(sendReadReceiptsProvider.notifier).setEnabled(v),
    );
  }
}

/// Whether the coarse media category may travel to the push service, so a
/// notification can read "X sent a photo" (default ON, see
/// [pushMediaKindProvider]).
class _PushMediaKindTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(pushMediaKindProvider);
    return PrivacySwitchTile(
      tileKey: 'push_media_kind_toggle',
      icon: Icons.image_outlined,
      title: 'push_media_kind.enable'.tr(),
      info: 'push_media_kind.enable_hint'.tr(),
      value: enabled,
      onChanged: (v) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await ref.read(pushMediaKindProvider.notifier).setEnabled(v);
        } catch (_) {
          messenger.showSnackBar(
            SnackBar(content: Text('push_media_kind.save_error'.tr())),
          );
        }
      },
    );
  }
}

/// Whether the reaction emoji may travel to the push service, so a notification
/// can read "X reacted with 👍" (default ON since 00073, see
/// [pushReactionEmojiProvider] — it hands over message content, not a category,
/// which is why the switch spells out what it costs).
class _PushReactionEmojiTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(pushReactionEmojiProvider);
    return PrivacySwitchTile(
      tileKey: 'push_reaction_emoji_toggle',
      icon: Icons.emoji_emotions_outlined,
      title: 'push_reaction_emoji.enable'.tr(),
      info: 'push_reaction_emoji.enable_hint'.tr(),
      value: enabled,
      onChanged: (v) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await ref.read(pushReactionEmojiProvider.notifier).setEnabled(v);
        } catch (_) {
          messenger.showSnackBar(
            SnackBar(content: Text('push_reaction_emoji.save_error'.tr())),
          );
        }
      },
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
    if (!ShareSuggestionsChannel.isSupported) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(shareSuggestionsEnabledProvider);
    return PrivacySwitchTile(
      tileKey: 'share_suggestions_toggle',
      icon: Icons.ios_share,
      title: 'share_suggestions.enable'.tr(),
      info: 'share_suggestions.enable_hint'.tr(),
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
                  SnackBar(content: Text('app_lock.at_rest_unavailable'.tr())),
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
