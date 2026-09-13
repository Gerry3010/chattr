// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/recovery/recovery_service.dart';
import '../../features/screen_security/screen_security_controller.dart';

/// Enable recovery: generate a 24-word phrase, enroll its public key
/// server-side, and show the phrase once (copyable, with a "store it in a
/// password manager" warning and an explicit confirmation before it disappears).
class RecoverySettingsScreen extends ConsumerWidget {
  const RecoverySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrolled = ref.watch(recoveryEnrolledProvider).asData?.value ?? false;
    return Scaffold(
      appBar: AppBar(title: Text('settings.recovery.title'.tr())),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'settings.recovery.intro'.tr(),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),
          if (enrolled)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: Icon(Icons.verified_user_outlined,
                    color: Theme.of(context).colorScheme.onSecondaryContainer),
                title: Text('settings.recovery.active_title'.tr()),
                subtitle: Text('settings.recovery.active_subtitle'.tr()),
              ),
            ),
          if (enrolled) const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('recovery_enable_button'),
            onPressed: () => _enable(context, ref, enrolled),
            icon: Icon(enrolled ? Icons.autorenew : Icons.vpn_key_outlined),
            label: Text(
              (enrolled ? 'settings.recovery.regenerate' : 'settings.recovery.enable').tr(),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'settings.recovery.footnote'.tr(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _enable(BuildContext context, WidgetRef ref, bool alreadyEnrolled) async {
    // Re-enrolling replaces the old phrase server-side (enroll upserts the
    // public key), silently invalidating whatever the user saved before — so
    // confirm first if they already have one.
    if (alreadyEnrolled) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('settings.recovery.regenerate_confirm_title'.tr()),
          content: Text('settings.recovery.regenerate_confirm_body'.tr()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('common.cancel'.tr()),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text('settings.recovery.regenerate'.tr()),
            ),
          ],
        ),
      );
      if (proceed != true || !context.mounted) return;
    }

    final service = ref.read(recoveryServiceProvider);
    final messenger = ScaffoldMessenger.of(context);

    final mnemonic = service.generateMnemonic();
    try {
      // Enroll the public key BEFORE revealing the phrase — if the server call
      // fails, the phrase is worthless and we don't show it.
      await service.enroll(mnemonic);
    } on RecoveryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
      return;
    }
    ref.invalidate(recoveryEnrolledProvider);
    if (!context.mounted) return;
    await _showPhraseOnce(context, ref, mnemonic);
    // Explicit success feedback once the user has confirmed they saved it.
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text('settings.recovery.enabled_success'.tr())),
      );
    }
  }

  Future<void> _showPhraseOnce(
      BuildContext context, WidgetRef ref, String mnemonic) {
    // Shield the one-time reveal from screenshots / screen recording / the
    // recent-apps preview for its whole duration, even on a default install
    // where the user hasn't enabled screen security (audit L2). Restored to the
    // user's actual preference afterwards.
    return ref.read(screenSecurityProvider.notifier).secureWhile(() {
      return showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
        final confirmed = ValueNotifier<bool>(false);
        return AlertDialog(
          title: Text('settings.recovery.phrase_title'.tr()),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('settings.recovery.phrase_warning'.tr()),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    mnemonic,
                    key: const ValueKey('recovery_phrase_text'),
                    style: const TextStyle(fontFamily: 'monospace', height: 1.6),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: mnemonic));
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text('settings.recovery.copied'.tr())),
                      );
                      // Best-effort auto-wipe of the live clipboard slot ~30 s
                      // later so the phrase doesn't sit there indefinitely (audit
                      // L2). Only clears if it's still our value. NOTE: this
                      // cannot evict clipboard *history* (Gboard/Samsung) or an
                      // already-synced universal/Handoff clipboard, and is lost
                      // if the app is killed within the window — copying a secret
                      // is inherently leaky, so manual transcription is safer.
                      Future.delayed(const Duration(seconds: 30), () async {
                        final current =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        if (current?.text == mnemonic) {
                          await Clipboard.setData(
                              const ClipboardData(text: ''));
                        }
                      });
                    },
                    icon: const Icon(Icons.copy),
                    label: Text('settings.recovery.copy'.tr()),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: confirmed,
                  builder: (_, value, _) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: value,
                    onChanged: (v) => confirmed.value = v ?? false,
                    title: Text('settings.recovery.confirm_saved'.tr()),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ValueListenableBuilder<bool>(
              valueListenable: confirmed,
              builder: (_, value, _) => FilledButton(
                onPressed: value ? () => Navigator.pop(dialogContext) : null,
                child: Text('settings.recovery.done'.tr()),
              ),
            ),
          ],
        );
        },
      );
    });
  }
}
