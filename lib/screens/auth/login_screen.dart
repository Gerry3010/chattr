// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../core/navigation/app_page_route.dart';
import '../../features/auth/auth_controller.dart';
import 'recovery_screen.dart';

class LoginScreen extends HookConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usernameController = useTextEditingController();
    final isLoading = useState(false);

    Future<void> handleLogin() async {
      if (usernameController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('login.error_empty_username'.tr())),
        );
        return;
      }

      isLoading.value = true;
      try {
        // Anonymous Auth + Profile Creation in one step
        await ref.read(authControllerProvider.notifier).loginWithUsername(
          usernameController.text.trim(),
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('login.error_failed'.tr(args: [e.toString()]))),
          );
        }
      } finally {
        isLoading.value = false;
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo / Title
              const Icon(
                Icons.chat_bubble_outline,
                size: 80,
                color: Colors.blue,
              ),
              const SizedBox(height: 16),
              Text(
                'app_name'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'login.tagline'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 48),

              // Username Input
              TextField(
                controller: usernameController,
                decoration: InputDecoration(
                  labelText: 'login.username_label'.tr(),
                  hintText: 'login.username_hint'.tr(),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => handleLogin(),
                enabled: !isLoading.value,
              ),
              const SizedBox(height: 24),

              // Login Button
              FilledButton(
                onPressed: isLoading.value ? null : handleLogin,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  child: isLoading.value
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('login.button'.tr()),
                ),
              ),
              const SizedBox(height: 8),

              // Recover an existing identity from a recovery phrase.
              TextButton(
                key: const ValueKey('login_recover_button'),
                onPressed: isLoading.value
                    ? null
                    : () => Navigator.push(
                          context,
                          appPageRoute<void>(builder: (_) => const RecoveryScreen()),
                        ),
                child: Text('login.recover_link'.tr()),
              ),
              const SizedBox(height: 8),

              // Info Text
              Text(
                'login.privacy_info'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
