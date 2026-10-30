// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backup/backup_service.dart';

/// Create / restore an encrypted backup of this device's identity + keys — the
/// safety net against a wipe (anonymous auth has no recovery). The backup does
/// NOT contain message history; restoring gets you back into every chat and
/// able to decrypt future messages. See lib/core/backup/backup_service.dart.
class BackupSettingsScreen extends ConsumerWidget {
  const BackupSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('settings.backup.title'.tr())),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'settings.backup.intro'.tr(),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey('backup_create_button'),
            onPressed: () => _createBackup(context, ref),
            icon: const Icon(Icons.save_alt),
            label: Text('settings.backup.create'.tr()),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('backup_restore_button'),
            onPressed: () => _restoreBackup(context, ref),
            icon: const Icon(Icons.restore),
            label: Text('settings.backup.restore'.tr()),
          ),
          const SizedBox(height: 24),
          Text(
            'settings.backup.footnote'.tr(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _createBackup(BuildContext context, WidgetRef ref) async {
    final passphrase = await _askPassphrase(context, confirm: true);
    if (passphrase == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ref.read(backupServiceProvider).createBackup(passphrase);
      final stamp = DateTime.now().toIso8601String().split('T').first;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              name: 'chattr-backup-$stamp.chattrbackup',
              mimeType: 'application/octet-stream',
            ),
          ],
          subject: 'settings.backup.file_subject'.tr(),
        ),
      );
    } on BackupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_describe(e))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }

  Future<void> _restoreBackup(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.backup.restore_confirm_title'.tr()),
        content: Text('settings.backup.restore_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('settings.backup.restore'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.firstOrNull;
    if (file == null || file.bytes == null || !context.mounted) return;

    final passphrase = await _askPassphrase(context, confirm: false);
    if (passphrase == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(backupServiceProvider).restoreBackup(file.bytes!, passphrase);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text('settings.backup.restore_done_title'.tr()),
          content: Text('settings.backup.restore_done_body'.tr()),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('common.ok'.tr()),
            ),
          ],
        ),
      );
    } on BackupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_describe(e))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }

  /// The user-facing text for [e]; the exception's own message is English and
  /// meant for the log.
  static String _describe(BackupException e) => switch (e.error) {
        BackupError.noSession => 'settings.backup.error.no_session'.tr(),
        BackupError.noEncryptionKey =>
          'settings.backup.error.no_encryption_key'.tr(),
        BackupError.noRefreshToken =>
          'settings.backup.error.no_refresh_token'.tr(),
        BackupError.badFile => 'settings.backup.error.bad_file'.tr(),
        BackupError.wrongPassphrase =>
          'settings.backup.error.wrong_passphrase'.tr(),
        BackupError.malformed => 'settings.backup.error.malformed'.tr(),
        BackupError.sessionExpired =>
          'settings.backup.error.session_expired'.tr(),
        BackupError.accountMismatch =>
          'settings.backup.error.account_mismatch'.tr(),
        null => e.message,
      };

  /// Prompts for a passphrase. When [confirm] is true, requires a matching
  /// second entry (create flow); otherwise a single field (restore flow).
  Future<String?> _askPassphrase(BuildContext context, {required bool confirm}) {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          confirm
              ? 'settings.backup.passphrase_set_title'.tr()
              : 'settings.backup.passphrase_enter_title'.tr(),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (confirm)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'settings.backup.passphrase_hint'.tr(),
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ),
              TextFormField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'settings.backup.passphrase_label'.tr(),
                ),
                validator: (v) => (v == null || v.length < 8)
                    ? 'settings.backup.passphrase_too_short'.tr()
                    : null,
              ),
              if (confirm)
                TextFormField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'settings.backup.passphrase_confirm_label'.tr(),
                  ),
                  validator: (v) => v != controller.text
                      ? 'settings.backup.passphrase_mismatch'.tr()
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext, controller.text);
              }
            },
            child: Text('common.ok'.tr()),
          ),
        ],
      ),
    );
  }
}
