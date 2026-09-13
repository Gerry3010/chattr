// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/recovery/recovery_service.dart';

/// Recover an existing identity by entering the 24-word recovery phrase. On
/// success the app is logged in as the original account (memberships intact).
class RecoveryScreen extends HookConsumerWidget {
  const RecoveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final isLoading = useState(false);

    Future<void> handleRecover() async {
      final phrase = controller.text.trim();
      if (!RecoveryCrypto.validateMnemonic(phrase)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('login.recovery.invalid_phrase'.tr())),
        );
        return;
      }
      isLoading.value = true;
      try {
        await ref.read(authControllerProvider.notifier).recoverWithPhrase(phrase);
        // Auth state flips and the root swaps to the chat list underneath; this
        // pushed screen (and the login screen below it) must be popped so the
        // user lands on their restored chats instead of staying here.
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } catch (e) {
        if (context.mounted) {
          final msg = e is RecoveryException
              ? e.message
              : 'login.recovery.failed'.tr(args: [e.toString()]);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
      } finally {
        if (context.mounted) isLoading.value = false;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text('login.recovery.title'.tr())),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'login.recovery.intro'.tr(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('recovery_phrase_input'),
                controller: controller,
                autofocus: true,
                minLines: 3,
                maxLines: 5,
                enabled: !isLoading.value,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => handleRecover(),
                decoration: InputDecoration(
                  labelText: 'login.recovery.phrase_label'.tr(),
                  hintText: 'login.recovery.phrase_hint'.tr(),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('recovery_submit_button'),
                onPressed: isLoading.value ? null : handleRecover,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: isLoading.value
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('login.recovery.submit'.tr()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
